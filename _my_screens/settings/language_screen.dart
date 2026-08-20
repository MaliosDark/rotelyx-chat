/// Language selection.
///
/// The four translations are kept
/// because they are the part of it worth keeping.
library;

import '../../config.dart';

class LanguageScreen extends StatefulWidget {
  const LanguageScreen({super.key});

  @override
  State<LanguageScreen> createState() => _LanguageScreenState();
}

class _LanguageScreenState extends State<LanguageScreen> {
  static const _languages = <({String code, String label, bool rtl})>[
    (code: 'en', label: 'English', rtl: false),
    (code: 'ar', label: 'العربية', rtl: true),
    (code: 'hi', label: 'हिन्दी', rtl: false),
    (code: 'kr', label: '한국어', rtl: false),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = appCtrl.appTheme;

    return Scaffold(
      backgroundColor: theme.screenBG,
      appBar: AppBar(
        backgroundColor: theme.boxBg,
        foregroundColor: theme.darkText,
        title: const Text('Language'),
      ),
      body: ListView(
        children: [
          for (final language in _languages)
            RadioListTile<String>(
              value: language.code,
              groupValue: appCtrl.languageVal,
              activeColor: theme.primary,
              title: Text(language.label,
                  style: TextStyle(color: theme.darkText)),
              onChanged: (code) {
                if (code == null) return;
                setState(() => appCtrl.setLanguage(code, rtl: language.rtl));
                Get.updateLocale(Locale(code));
              },
            ),
        ],
      ),
    );
  }
}
