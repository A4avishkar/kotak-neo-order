import 'package:flutter/material.dart';
import '../models/credentials.dart';
import '../services/credentials_service.dart';

class CredentialsScreen extends StatefulWidget {
  const CredentialsScreen({super.key});

  @override
  State<CredentialsScreen> createState() => _CredentialsScreenState();
}

class _CredentialsScreenState extends State<CredentialsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _consumerKeyController = TextEditingController();
  final _mobileNumberController = TextEditingController();
  final _mpinController = TextEditingController();
  final _uccController = TextEditingController();
  final _totpSecretController = TextEditingController();
  final _neoFinKeyController = TextEditingController(text: 'neotradeapi');
  final _credentialsService = CredentialsService();
  bool _isLoading = false;
  bool _obscureMpin = true;
  bool _obscureTotp = true;

  @override
  void initState() {
    super.initState();
    _loadCredentials();
  }

  Future<void> _loadCredentials() async {
    final creds = await _credentialsService.getCredentials();
    if (creds != null) {
      setState(() {
        _consumerKeyController.text = creds.consumerKey;
        _mobileNumberController.text = creds.mobileNumber;
        _mpinController.text = creds.mpin;
        _uccController.text = creds.ucc;
        _totpSecretController.text = creds.totpSecret;
        _neoFinKeyController.text = creds.neoFinKey ?? 'neotradeapi';
      });
    }
  }

  Future<void> _saveCredentials() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final credentials = Credentials(
        consumerKey: _consumerKeyController.text.trim(),
        mobileNumber: _mobileNumberController.text.trim(),
        mpin: _mpinController.text.trim(),
        ucc: _uccController.text.trim(),
        totpSecret: _totpSecretController.text.trim(),
        neoFinKey: _neoFinKeyController.text.trim().isEmpty
            ? null
            : _neoFinKeyController.text.trim(),
      );

      if (!credentials.isValid) {
        throw Exception('Please fill all required fields');
      }

      await _credentialsService.saveCredentials(credentials);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Credentials saved successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _consumerKeyController.dispose();
    _mobileNumberController.dispose();
    _mpinController.dispose();
    _uccController.dispose();
    _totpSecretController.dispose();
    _neoFinKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kotak Neo Credentials'),
        backgroundColor: Colors.blue.shade700,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 20),
              Icon(
                Icons.security,
                size: 64,
                color: Colors.blue.shade700,
              ),
              const SizedBox(height: 20),
              const Text(
                'Enter your Kotak Neo API credentials',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),
              TextFormField(
                controller: _consumerKeyController,
                decoration: const InputDecoration(
                  labelText: 'Consumer Key *',
                  hintText: 'Enter your consumer key',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.key),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter consumer key';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _mobileNumberController,
                decoration: const InputDecoration(
                  labelText: 'Mobile Number *',
                  hintText: 'Enter mobile number',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone),
                ),
                keyboardType: TextInputType.phone,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter mobile number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _mpinController,
                decoration: InputDecoration(
                  labelText: 'MPIN *',
                  hintText: 'Enter MPIN',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureMpin ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureMpin = !_obscureMpin;
                      });
                    },
                  ),
                ),
                obscureText: _obscureMpin,
                keyboardType: TextInputType.number,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter MPIN';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _uccController,
                decoration: const InputDecoration(
                  labelText: 'UCC *',
                  hintText: 'Enter UCC',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.account_circle),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter UCC';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _totpSecretController,
                decoration: InputDecoration(
                  labelText: 'TOTP Secret *',
                  hintText: 'Enter TOTP secret',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.vpn_key),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureTotp ? Icons.visibility : Icons.visibility_off,
                    ),
                    onPressed: () {
                      setState(() {
                        _obscureTotp = !_obscureTotp;
                      });
                    },
                  ),
                ),
                obscureText: _obscureTotp,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter TOTP secret';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _neoFinKeyController,
                decoration: const InputDecoration(
                  labelText: 'Neo Fin Key (Optional)',
                  hintText: 'Default: neotradeapi',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.settings),
                ),
              ),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: _isLoading ? null : _saveCredentials,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade700,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : const Text(
                        'Save Credentials',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

