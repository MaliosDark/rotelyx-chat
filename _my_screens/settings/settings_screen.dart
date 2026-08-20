/// Settings.
///
/// Everything here is local. There is no remote configuration in this build and
/// no mechanism to add one: no server decides whether this client may send a
/// message, create a group, or skip anything.
library;

import '../../config.dart';
import '../../rotelyx/rotelyx_config.dart';
import '../../rotelyx/rotelyx_wasm.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = appCtrl.appTheme;

    return Scaffold(
      backgroundColor: theme.screenBG,
      appBar: AppBar(
        backgroundColor: theme.boxBg,
        foregroundColor: theme.darkText,
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            value: appCtrl.isTheme,
            onChanged: (v) => setState(() => appCtrl.updateTheme(v)),
            title: Text('Dark theme', style: TextStyle(color: theme.darkText)),
            activeColor: theme.primary,
          ),
          ListTile(
            title: Text('Language', style: TextStyle(color: theme.darkText)),
            subtitle: Text(appCtrl.languageVal,
                style: TextStyle(color: theme.greyText)),
            onTap: () => Get.toNamed(routeName.languageScreen),
          ),
          const Divider(),
          _row(theme, 'Display name',
              appCtrl.displayName.isEmpty ? 'not set' : appCtrl.displayName),
          _row(theme, 'Mailbox', Uri.parse(rotelyxConfig.mailbox).host),
          _row(theme, 'Protocol',
              RotelyxWasm.isReady ? RotelyxWasm.protocolVersion : 'not loaded'),
          _row(theme, 'Conversation',
              rotelyx.state == RotelyxState.joined
                  ? 'established, epoch ${rotelyx.epoch}'
                  : 'none'),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                border: Border.all(color: theme.borderColor),
                borderRadius: BorderRadius.circular(10)),
            child: Text(
              'This client contacts no third party. The only outbound '
              'connection is the mailbox above, which never learns who sent a '
              'message and never sees plaintext.\n\n'
              'Rotelyx is unaudited and pre-release.',
              style:
                  TextStyle(fontSize: 11, color: theme.greyText, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(AppTheme theme, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(fontSize: 12, color: theme.greyText)),
            const Spacer(),
            Flexible(
              child: SelectableText(value,
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 12, color: theme.darkText)),
            ),
          ],
        ),
      );
}
