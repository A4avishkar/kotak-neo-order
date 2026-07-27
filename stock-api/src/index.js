export default {
	async fetch(request, env, ctx) {
		// Handle CORS Preflight requests
		if (request.method === "OPTIONS") {
			return new Response(null, {
				status: 204,
				headers: {
					"Access-Control-Allow-Origin": "*",
					"Access-Control-Allow-Methods": "GET, POST, OPTIONS",
					"Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
					"Access-Control-Max-Age": "86400"
				}
			});
		}

		const url = new URL(request.url);
		
		// Parse query parameters
		const query = url.searchParams.get("symbol") || url.searchParams.get("q"); // e.g. ?q=RELIANCE or ?symbol=RELIANCE26FEB262500CE
		const segment = url.searchParams.get("segment") || url.searchParams.get("exch_seg"); // e.g. nse_fo, nse_cm
		const optionType = url.searchParams.get("option_type"); // e.g. CE, PE
		const expiryParam = url.searchParams.get("expiry"); // e.g. 28JUL26, 28july2026, or 1469716200
		const exact = url.searchParams.get("exact") === "true"; // e.g. exact=true for exact base symbol matching
		const limit = url.searchParams.get("limit") || "20";

		// 1. Basic Validation
		if (!query) {
			return new Response(JSON.stringify({ 
				error: "Please provide a query symbol or parameter. Example: ?q=RELIANCE or ?q=NIFTY&segment=nse_fo" 
			}), {
				status: 400,
				headers: { 
					"Content-Type": "application/json",
					"Access-Control-Allow-Origin": "*"
				}
			});
		}

		// Helper: Decode Kotak 1980-epoch or string expiry to Supabase query filter
		let expiryPattern = "";
		if (expiryParam) {
			const cleanExp = expiryParam.trim().toUpperCase();
			const numericVal = parseInt(cleanExp, 10);
			if (!isNaN(numericVal) && numericVal > 100000000) {
				// Kotak 1980 epoch shift (+315,532,800 seconds)
				const seconds = numericVal > 10000000000 ? Math.floor(numericVal / 1000) : numericVal;
				const realSeconds = seconds + 315532800;
				const dt = new Date(realSeconds * 1000);
				const months = ['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
				const month = months[dt.getUTCMonth()];
				const year = String(dt.getUTCFullYear()).slice(-2);
				expiryPattern = `${year}${month}`; // e.g. 26JUL
			} else {
				// Formats like 28JUL26 or 28JULY2026
				const match = cleanExp.match(/^(\d{2})([A-Z]{3,4})(\d{2,4})$/);
				if (match) {
					const month = match[2].slice(0, 3);
					const year = match[3].slice(-2);
					// Matches Kotak trading symbol pattern NIFTY26JUL...
					expiryPattern = `${year}${month}`;
				} else {
					expiryPattern = cleanExp;
				}
			}
		}

		// 2. Supabase Keys
		const SUPABASE_URL = "https://lztwmrthpdkeeguedvqh.supabase.co";
		const SUPABASE_ANON_KEY = "sb_publishable_mSbAij70Af_IiloKZPnIgg_pm5Dkz8w";

		// 3. Build Supabase query URL
		let supabaseQuery = `${SUPABASE_URL}/rest/v1/scrip_master?`;
		
		const queryUpper = query.toUpperCase();
		if (exact) {
			// Exact match on the underlying symbol name (e.g. exactly NIFTY options)
			supabaseQuery += `symbol_name=eq.${queryUpper}`;
		} else {
			// Flexible prefix search: Matches base asset name OR specific trading symbol
			supabaseQuery += `or=(trading_symbol.ilike.${queryUpper}*,symbol_name.ilike.${queryUpper}*)`;
		}
		
		if (segment) {
			supabaseQuery += `&exch_seg=eq.${segment.toLowerCase()}`;
		}
		if (optionType) {
			supabaseQuery += `&option_type=eq.${optionType.toUpperCase()}`;
		}
		if (expiryPattern) {
			supabaseQuery += `&trading_symbol=ilike.*${expiryPattern}*`;
		}
		
		supabaseQuery += `&order=expiry_date.asc,strike_price.asc`;
		supabaseQuery += `&limit=${limit}`;

		// 4. Bypass Cloudflare Edge Cache so app gets fresh sorted rows from Supabase immediately
		// const cache = caches.default;
		// let cachedResponse = await cache.match(request);
		// if (cachedResponse) return cachedResponse;

		console.log("Fetching from Supabase:", supabaseQuery);

		// 5. Fetch from Supabase
		try {
			const response = await fetch(supabaseQuery, {
				headers: {
					"apikey": SUPABASE_ANON_KEY,
					"Authorization": `Bearer ${SUPABASE_ANON_KEY}`,
					"Content-Type": "application/json"
				}
			});

			if (!response.ok) {
				const errText = await response.text();
				return new Response(JSON.stringify({ error: "Supabase query error", details: errText }), {
					status: response.status,
					headers: { 
						"Content-Type": "application/json",
						"Access-Control-Allow-Origin": "*"
					}
				});
			}

			const data = await response.json();

			// 6. Save the response to Cache for 24 hours (86400 seconds)
			const responseToCache = new Response(JSON.stringify(data), {
				headers: {
					"Content-Type": "application/json",
					"Cache-Control": "s-maxage=86400",
					"Access-Control-Allow-Origin": "*" // Allow your Flutter app to read it
				}
			});

			return responseToCache;

		} catch (error) {
			return new Response(JSON.stringify({ error: "Server error", message: error.message }), {
				status: 500,
				headers: { 
					"Content-Type": "application/json",
					"Access-Control-Allow-Origin": "*"
				}
			});
		}
	},
};
