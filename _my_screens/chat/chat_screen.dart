/// The conversation.
///
/// The safety number sits at the top of the screen rather than behind a menu,
/// because it is the only thing that detects the failure the pairing modes
/// cannot prevent: someone who learned the meeting phrase early and answered in
/// the intended party's place. Both sides read it aloud over a channel the
/// attacker does not control. Hidden behind two taps, it does not get compared.
library;

import 'dart:async';

import '../../config.dart';
import '../../rotelyx/rotelyx_config.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<RotelyxMessage> _messages = [];

  StreamSubscription<RotelyxMessage>? _incoming;
  StreamSubscription<RotelyxState>? _groupChanges;

  @override
  void initState() {
    super.initState();

    // The group can change under us: someone arrives, the epoch moves, the
    // safety number and roster change with it. The service reports that as a
    // state event rather than a message, so both are watched.
    _groupChanges = rotelyx.stateChanges.listen((_) {
      if (mounted) setState(() {});
    });

    _incoming = rotelyx.messages.listen((message) {
      if (!mounted) return;
      setState(() => _messages.add(message));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
        }
      });
    });
  }

  @override
  void dispose() {
    _groupChanges?.cancel();
    _incoming?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    if (rotelyx.send(text)) _input.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = appCtrl.appTheme;

    return Scaffold(
      backgroundColor: theme.screenBG,
      body: SafeArea(
        child: Column(
          children: [
            _safetyBar(theme),
            Expanded(
              child: _messages.isEmpty
                  ? _empty(theme)
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(16),
                      itemCount: _messages.length,
                      itemBuilder: (_, i) => _bubble(theme, _messages[i]),
                    ),
            ),
            _composer(theme),
          ],
        ),
      ),
    );
  }

  Widget _safetyBar(AppTheme theme) {
    final number = rotelyx.safetyNumber;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: theme.boxBg,
        border: Border(bottom: BorderSide(color: theme.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Safety number',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.greyText)),
              const Spacer(),
              Text('epoch ${rotelyx.epoch} · ${rotelyx.memberCount} here',
                  style: TextStyle(fontSize: 11, color: theme.greyText)),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            number ?? 'not established',
            style: TextStyle(
                fontSize: 16,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
                color: theme.darkText),
          ),
          const SizedBox(height: 4),
          Text(
            'Read this aloud to the others. Comparing it here, over this same '
            'connection, proves nothing.',
            style: TextStyle(fontSize: 10, color: theme.greyText, height: 1.4),
          ),
          if (rotelyx.roster.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              // Labels each member chose, authenticated by the group but not by
              // anything outside it. Two people may pick the same one.
              rotelyx.roster.join(' · '),
              style: TextStyle(fontSize: 11, color: theme.greyText),
            ),
          ],
        ],
      ),
    );
  }

  Widget _empty(AppTheme theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Conversation established.',
                  style: TextStyle(color: theme.darkText, fontSize: 14)),
              const SizedBox(height: 8),
              Text(
                'Messages travel under tags that rotate every hour. Anyone who '
                'knew the meeting phrase has lost the thread.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 12, color: theme.greyText, height: 1.5),
              ),
              const SizedBox(height: 20),
              _sessionNotice(theme),
            ],
          ),
        ),
      );

  /// Two limitations that will otherwise be discovered as data loss.
  Widget _sessionNotice(AppTheme theme) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            border: Border.all(color: theme.borderColor),
            borderRadius: BorderRadius.circular(10)),
        child: Text(
          'This build keeps the conversation in memory only. Reloading the page '
          'ends it, and nothing is stored on this device.\n\n'
          'In the browser every message travels through the mailbox at '
          '${Uri.parse(rotelyxConfig.mailbox).host}. Direct peer-to-peer needs '
          'the native client.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: theme.greyText, height: 1.5),
        ),
      );

  Widget _bubble(AppTheme theme, RotelyxMessage message) => Align(
        alignment: message.mine ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72),
          decoration: BoxDecoration(
            color: message.mine ? theme.primary : theme.boxBg,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(message.mine ? 16 : 4),
              bottomRight: Radius.circular(message.mine ? 4 : 16),
            ),
          ),
          child: Text(
            message.text,
            style: TextStyle(
                fontSize: 14,
                color: message.mine ? theme.sameWhite : theme.darkText),
          ),
        ),
      );

  Widget _composer(AppTheme theme) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.boxBg,
          border: Border(top: BorderSide(color: theme.divider)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                style: TextStyle(color: theme.darkText),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  fillColor: theme.textField,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: theme.primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _send,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(Icons.arrow_upward,
                      color: theme.sameWhite, size: 20),
                ),
              ),
            ),
          ],
        ),
      );
}
