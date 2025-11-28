import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/credentials_service.dart';
import '../services/market_data_service.dart';
import 'credentials_screen.dart';
import 'database_screen.dart';
import 'support_screen.dart';
import 'terms_and_conditions_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _credentialsService = CredentialsService();
  TimeOfDay _startTime = const TimeOfDay(hour: 9, minute: 15);
  TimeOfDay _endTime = const TimeOfDay(hour: 15, minute: 30);
  double _oiUpdateIntervalSeconds = 30;
  bool _websocketEnabled = true; // Default to enabled
  bool _oiAndOptionChainEnabled = true; // Default to enabled
  
  // Text controllers for custom input
  final TextEditingController _oiIntervalController = TextEditingController();
  
  static const String _prefsKeyOiUpdateInterval = 'oi_update_interval_seconds';
  static const String _prefsKeyStartTimeHour = 'trading_start_time_hour';
  static const String _prefsKeyStartTimeMinute = 'trading_start_time_minute';
  static const String _prefsKeyEndTimeHour = 'trading_end_time_hour';
  static const String _prefsKeyEndTimeMinute = 'trading_end_time_minute';
  static const String _prefsKeyWebsocketEnabled = 'websocket_enabled';
  static const String _prefsKeyOiAndOptionChainEnabled = 'oi_and_option_chain_enabled';

  @override
  void initState() {
    super.initState();
    _loadIntervals();
    _loadTradingHours();
    _loadWebsocketSetting();
    _loadOiAndOptionChainSetting();
  }

  @override
  void dispose() {
    _oiIntervalController.dispose();
    super.dispose();
  }

  Future<void> _loadIntervals() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load OI update interval
    final savedOi = prefs.getDouble(_prefsKeyOiUpdateInterval);
    if (savedOi != null) {
      setState(() {
        _oiUpdateIntervalSeconds = savedOi;
        _oiIntervalController.text = savedOi.toStringAsFixed(0);
      });
    } else {
      _oiIntervalController.text = _oiUpdateIntervalSeconds.toStringAsFixed(0);
    }
  }

  Future<void> _loadTradingHours() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Load start time
    final startHour = prefs.getInt(_prefsKeyStartTimeHour);
    final startMinute = prefs.getInt(_prefsKeyStartTimeMinute);
    if (startHour != null && startMinute != null) {
      setState(() {
        _startTime = TimeOfDay(hour: startHour, minute: startMinute);
      });
    }
    
    // Load end time
    final endHour = prefs.getInt(_prefsKeyEndTimeHour);
    final endMinute = prefs.getInt(_prefsKeyEndTimeMinute);
    if (endHour != null && endMinute != null) {
      setState(() {
        _endTime = TimeOfDay(hour: endHour, minute: endMinute);
      });
    }
  }

  Future<void> _saveTradingHours() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_prefsKeyStartTimeHour, _startTime.hour);
    await prefs.setInt(_prefsKeyStartTimeMinute, _startTime.minute);
    await prefs.setInt(_prefsKeyEndTimeHour, _endTime.hour);
    await prefs.setInt(_prefsKeyEndTimeMinute, _endTime.minute);
  }


  Future<void> _saveOiUpdateInterval(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefsKeyOiUpdateInterval, value);
    setState(() {
      _oiUpdateIntervalSeconds = value;
      _oiIntervalController.text = value.toStringAsFixed(0);
    });
  }

  Future<void> _loadWebsocketSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_prefsKeyWebsocketEnabled);
    final websocketEnabled = enabled ?? true; // Default to enabled if not set
    setState(() {
      _websocketEnabled = websocketEnabled;
    });
    // Update MarketDataService immediately to sync
    await MarketDataService.setWebsocketEnabled(websocketEnabled);
  }

  Future<void> _updateWebsocketSetting(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKeyWebsocketEnabled, enabled);
    setState(() {
      _websocketEnabled = enabled;
    });
    // Update MarketDataService immediately
    await MarketDataService.setWebsocketEnabled(enabled);
  }

  Future<void> _loadOiAndOptionChainSetting() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_prefsKeyOiAndOptionChainEnabled);
    setState(() {
      _oiAndOptionChainEnabled = enabled ?? true; // Default to enabled if not set
    });
  }

  Future<void> _updateOiAndOptionChainSetting(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKeyOiAndOptionChainEnabled, enabled);
    setState(() {
      _oiAndOptionChainEnabled = enabled;
    });
  }


  void _onOiIntervalTextChanged(String value) {
    final parsed = double.tryParse(value);
    if (parsed != null && parsed >= 5 && parsed <= 300) {
      _saveOiUpdateInterval(parsed);
    }
  }

  Future<void> _pickTime(bool isStart) async {
    final initial = isStart ? _startTime : _endTime;
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
        } else {
          _endTime = picked;
        }
      });
      // Save trading hours to SharedPreferences
      await _saveTradingHours();
    }
  }

  void _openCredentials() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CredentialsScreen(
          onCredentialsSaved: () => Navigator.of(context).pop(true),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SettingsCard(
            title: 'Database',
            subtitle: 'Manage or inspect local database.',
            icon: Icons.storage_outlined,
            actionLabel: 'Open',
            onActionTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DatabaseScreen()),
              );
            },
          ),
          const SizedBox(height: 16),
          _SettingsCard(
            title: 'Trading Hours',
            subtitle: 'Set when automatic data fetch begins and ends.',
            icon: Icons.schedule_outlined,
            child: Row(
              children: [
                Expanded(
                  child: _SettingsChip(
                    label: 'Start',
                    value: '${_startTime.format(context)}',
                    onTap: () => _pickTime(true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _SettingsChip(
                    label: 'End',
                    value: '${_endTime.format(context)}',
                    onTap: () => _pickTime(false),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingsCard(
            title: 'OI Update Interval',
            subtitle: 'Choose how often Open Interest data is refreshed.',
            icon: Icons.bar_chart_outlined,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Slider(
                  min: 5,
                  max: 300,
                  divisions: 59,
                  value: _oiUpdateIntervalSeconds,
                  label: '${_oiUpdateIntervalSeconds.toStringAsFixed(0)} s',
                  onChanged: (value) {
                    _saveOiUpdateInterval(value);
                  },
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Interval: ${_oiUpdateIntervalSeconds.toStringAsFixed(0)} seconds',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 80,
                      child: TextField(
                        controller: _oiIntervalController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Custom',
                          hintText: '5-300',
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        style: const TextStyle(fontSize: 12),
                        onChanged: _onOiIntervalTextChanged,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingsCard(
            title: 'WebSocket Connection',
            subtitle: 'Enable or disable real-time market data via WebSocket.',
            icon: Icons.wifi_outlined,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    _websocketEnabled ? 'Enabled' : 'Disabled',
                    style: TextStyle(
                      color: _websocketEnabled ? Colors.green : Colors.orange,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Switch(
                  value: _websocketEnabled,
                  onChanged: (value) async {
                    await _updateWebsocketSetting(value);
                    // Show a message that app restart may be needed
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            value
                                ? 'WebSocket enabled. Restart app to apply changes.'
                                : 'WebSocket disabled. Restart app to apply changes.',
                          ),
                          duration: const Duration(seconds: 3),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingsCard(
            title: 'OI & Option Chain Data',
            subtitle: 'Enable or disable fetching Open Interest and Option Chain data.',
            icon: Icons.bar_chart_outlined,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    _oiAndOptionChainEnabled ? 'Enabled' : 'Disabled',
                    style: TextStyle(
                      color: _oiAndOptionChainEnabled ? Colors.green : Colors.orange,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Switch(
                  value: _oiAndOptionChainEnabled,
                  onChanged: (value) async {
                    await _updateOiAndOptionChainSetting(value);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            value
                                ? 'OI & Option Chain data enabled. Changes take effect immediately.'
                                : 'OI & Option Chain data disabled. Changes take effect immediately.',
                          ),
                          duration: const Duration(seconds: 3),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingsCard(
            title: 'Credentials',
            subtitle: 'Update your Kotak login details.',
            icon: Icons.vpn_key_outlined,
            actionLabel: 'Edit',
            onActionTap: _openCredentials,
          ),
          const SizedBox(height: 16),
          _SettingsCard(
            title: 'Terms and Conditions',
            subtitle: 'Read our terms and conditions.',
            icon: Icons.description_outlined,
            actionLabel: 'View',
            onActionTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const TermsAndConditionsScreen()),
              );
            },
          ),
          const SizedBox(height: 16),
          _SettingsCard(
            title: 'Support Developer',
            subtitle: 'Help support the development of this app.',
            icon: Icons.favorite_outline,
            actionLabel: 'Support',
            onActionTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SupportScreen()),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    this.child,
    this.actionLabel,
    this.onActionTap,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Widget? child;
  final String? actionLabel;
  final VoidCallback? onActionTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: Colors.white70),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ],
                  ),
                ),
                if (actionLabel != null)
                  TextButton(onPressed: onActionTap, child: Text(actionLabel!)),
              ],
            ),
            if (child != null) ...[const SizedBox(height: 16), child!],
          ],
        ),
      ),
    );
  }
}

class _SettingsChip extends StatelessWidget {
  const _SettingsChip({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white60)),
            const SizedBox(height: 4),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
