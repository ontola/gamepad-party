import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../navigation/open_website.dart';
import '../theme.dart';

/// Sign in right where the player is: an email field, then the 8-digit code
/// Splitscreen Club mails. The link in that email finishes it too.
/// [onSignedIn] runs once the code is accepted.
class EmailSignIn extends StatefulWidget {
  final AppState state;
  final VoidCallback? onSignedIn;
  const EmailSignIn({super.key, required this.state, this.onSignedIn});

  @override
  State<EmailSignIn> createState() => _EmailSignInState();
}

class _EmailSignInState extends State<EmailSignIn> {
  late final _email = TextEditingController(
    text: widget.state.accountEmail ?? '',
  );
  final _code = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
        if (_email.text.trim().isEmpty) {
          throw 'Enter your email first.';
        }
        await widget.state.requestSignInCode(_email.text);
        if (mounted) setState(() => _sent = true);
      });

  Future<void> _verify() => _run(() async {
        final message = await widget.state.verifySignInCode(_code.text);
        if (!mounted) return;
        toast(context, message);
        widget.onSignedIn?.call();
      });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (!_sent) {
      children.addAll([
        _FieldAndButton(
          field: TextField(
            key: const ValueKey('sign-in-email'),
            controller: _email,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.send,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              hintText: 'you@example.com',
              isDense: true,
              prefixIcon: Icon(Icons.mail_outline, size: 20),
            ),
            onSubmitted: (_) => _send(),
          ),
          button: FilledButton(
            key: const ValueKey('sign-in-send'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _busy ? null : _send,
            child: Text(_busy ? 'Sending…' : 'Email me a code'),
          ),
        ),
        const SizedBox(height: 2),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Hint('By signing in you accept the'),
            _Link(
              'terms',
              () => openWebsite(widget.state.cloud, '/docs/terms'),
            ),
            const Hint('and'),
            _Link(
              'privacy policy',
              () => openWebsite(widget.state.cloud, '/docs/privacy'),
            ),
          ],
        ),
      ]);
    } else {
      children.addAll([
        Hint(
          'We sent an 8-digit code to ${_email.text.trim()}. '
          'Open the email link on this device, or type the code here. '
          'It expires in 10 minutes.',
        ),
        if (kIsWeb)
          const Hint('Type the code here to keep playing in this tab.'),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('sign-in-code'),
                controller: _code,
                autofocus: true,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                maxLength: 8,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 22,
                  letterSpacing: 6,
                  fontFamily: 'monospace',
                ),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  hintText: '········',
                  counterText: '',
                  isDense: true,
                ),
                onChanged: (v) {
                  if (v.length == 8) _verify();
                },
                onSubmitted: (_) => _verify(),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              key: const ValueKey('sign-in-verify'),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              onPressed: _busy ? null : _verify,
              child: Text(_busy ? 'Signing in…' : 'Sign in'),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy
                ? null
                : () => setState(() {
                      _sent = false;
                      _code.clear();
                      _error = null;
                    }),
            child: const Text('Use another email or send a new code'),
          ),
        ),
      ]);
    }
    if (_error != null) {
      children.addAll([
        const SizedBox(height: 4),
        Text(_error!, style: const TextStyle(color: GnColors.warn)),
      ]);
    }
    return Column(
      key: const ValueKey('email-sign-in'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

/// A field with its button beside it, or under it when there is no room.
class _FieldAndButton extends StatelessWidget {
  final Widget field;
  final Widget button;
  const _FieldAndButton({required this.field, required this.button});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, size) {
          if (size.maxWidth < 340) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [field, const SizedBox(height: 8), button],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: field),
              const SizedBox(width: 8),
              button,
            ],
          );
        },
      );
}

class _Link extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _Link(this.label, this.onTap);
  @override
  Widget build(BuildContext context) => TextButton(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onTap,
        child: Text(label),
      );
}
