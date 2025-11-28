import 'package:flutter/material.dart';

class TermsAndConditionsScreen extends StatelessWidget {
  const TermsAndConditionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms and Conditions'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Terms and Conditions',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
            ),
            const SizedBox(height: 24),
            _buildSection(
              context,
              '1. Acceptance of Terms',
              'By accessing and using this application, you accept and agree to be bound by the terms and provision of this agreement.',
            ),
            _buildSection(
              context,
              '2. Use License',
              'Permission is granted to temporarily use this application for personal, non-commercial transitory viewing only. This is the grant of a license, not a transfer of title, and under this license you may not:\n\n'
              '• Modify or copy the materials\n'
              '• Use the materials for any commercial purpose\n'
              '• Attempt to reverse engineer any software contained in the application\n'
              '• Remove any copyright or other proprietary notations from the materials',
            ),
            _buildSection(
              context,
              '3. Disclaimer',
              'The materials in this application are provided on an "as is" basis. The application makes no warranties, expressed or implied, and hereby disclaims and negates all other warranties including, without limitation, implied warranties or conditions of merchantability, fitness for a particular purpose, or non-infringement of intellectual property or other violation of rights.',
            ),
            _buildSection(
              context,
              '4. Trading Risks',
              'Trading in financial markets involves substantial risk of loss and is not suitable for every investor. The value of investments may fluctuate, and investors may lose their entire investment. Past performance is not indicative of future results. You should carefully consider whether trading is suitable for you in light of your circumstances, knowledge, and financial resources.',
            ),
            _buildSection(
              context,
              '5. Data Accuracy',
              'While we strive to provide accurate and up-to-date information, we do not guarantee the accuracy, completeness, or timeliness of any data, quotes, or other information displayed in the application. Market data is provided for informational purposes only and should not be relied upon as the sole basis for investment decisions.',
            ),
            _buildSection(
              context,
              '6. Account Security',
              'You are responsible for maintaining the confidentiality of your account credentials, including but not limited to your consumer key, MPIN, TOTP secret, and other authentication information. You agree to notify us immediately of any unauthorized use of your account or any other breach of security.',
            ),
            _buildSection(
              context,
              '7. Limitation of Liability',
              'In no event shall the application or its suppliers be liable for any damages (including, without limitation, damages for loss of data or profit, or due to business interruption) arising out of the use or inability to use the materials in this application, even if the application or an authorized representative has been notified orally or in writing of the possibility of such damage.',
            ),
            _buildSection(
              context,
              '8. Third-Party Services',
              'This application may integrate with third-party services and APIs. We are not responsible for the availability, accuracy, or reliability of any third-party services. Your use of third-party services is subject to their respective terms and conditions.',
            ),
            _buildSection(
              context,
              '9. Modifications',
              'We reserve the right to modify these terms and conditions at any time without prior notice. Your continued use of the application after any such changes constitutes your acceptance of the new terms and conditions.',
            ),
            _buildSection(
              context,
              '10. Governing Law',
              'These terms and conditions are governed by and construed in accordance with the laws of India, and you irrevocably submit to the exclusive jurisdiction of the courts in that location.',
            ),
            const SizedBox(height: 32),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: Colors.blue),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'If you do not agree with any of these terms and conditions, you are prohibited from using this application.',
                      style: TextStyle(
                        color: Colors.blue.shade200,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white70,
                  height: 1.5,
                ),
          ),
        ],
      ),
    );
  }
}

