import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account.dart';
import '../apps.dart';
import '../layout.dart';
import '../link.dart';
import '../navigation/browser_host_stub.dart'
    if (dart.library.js_interop) '../navigation/browser_host_web.dart';
import '../navigation/host_room.dart';
import '../navigation/open_website.dart';
import '../theme.dart';
import 'mods_screen.dart' show GetTheApp;

/// "Host a room": what runs the TV screen. This phone (the Android app's
/// native host) or a PC by the TV, where splitscreen.club offers the
/// browser host and the Windows and Mac app.
class HostScreen extends StatelessWidget {
  final CloudApi cloud;

  /// Why this page can't be the TV screen; null when it can. Tests set it.
  final BrowserHostBlocker? blocker;
  final bool _blockerSet;

  /// The OS share sheet; tests replace it.
  final Future<ShareResult> Function(ShareParams)? share;

  const HostScreen({super.key, required this.cloud})
      : blocker = null,
        _blockerSet = false,
        share = null;

  const HostScreen.testing({
    super.key,
    required this.cloud,
    required this.blocker,
    this.share,
  }) : _blockerSet = true;

  static Future<void> open(BuildContext context, CloudApi cloud) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'host'),
          builder: (_) => HostScreen(cloud: cloud),
        ),
      );

  static const _then = [
    (
      Icons.sports_esports,
      'Grab a controller',
      'Press A to join. Phones join by scanning the QR code on the TV.',
    ),
    (
      Icons.bolt,
      'Play',
      'Pick games together. The next one starts in a second.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final blocker = _blockerSet ? this.blocker : browserHostBlocker();
    return Scaffold(
      appBar: AppBar(title: const Text('Host a room')),
      body: ContentWidth(
        maxWidth: 560,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const Text(
              'What runs the TV screen?',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Hint(
              'The TV shows the game, everyone plays on the couch. '
              'Pick what runs it.',
            ),
            const SizedBox(height: 16),
            if (Apps.supported) ...[
              const _ThisPhone(),
              const SizedBox(height: 12),
            ],
            _OnAPc(cloud: cloud, blocker: blocker, share: share),
            const SizedBox(height: 24),
            const Text(
              'Then',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            for (final step in _then)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(step.$1, color: GnColors.warn, size: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            step.$2,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Hint(step.$3),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A hosting option: an icon, a title and what it takes.
class _Option extends StatelessWidget {
  final IconData icon;
  final String title;
  final List<Widget> children;
  const _Option({
    super.key,
    required this.icon,
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(icon, color: GnColors.warn, size: 26),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        ),
      );
}

/// The Android app hosts on the phone itself (the native host).
class _ThisPhone extends StatelessWidget {
  const _ThisPhone();

  @override
  Widget build(BuildContext context) => _Option(
        key: const ValueKey('host-this-phone'),
        icon: Icons.phone_android,
        title: 'This phone',
        children: [
          const Hint(
            'This phone runs the games. Connect it to the TV with a cable '
            'or screen mirroring, or just play on the phone.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('host-phone'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => Apps.host(browserHost),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Host on this phone'),
          ),
        ],
      );
}

/// A PC by the TV: splitscreen.club offers the browser host and the
/// Windows and Mac app. Starts it right here when this browser can run it.
class _OnAPc extends StatelessWidget {
  final CloudApi cloud;
  final BrowserHostBlocker? blocker;
  final Future<ShareResult> Function(ShareParams)? share;
  const _OnAPc({required this.cloud, required this.blocker, this.share});

  @override
  Widget build(BuildContext context) {
    final here = blocker == null;
    return _Option(
      key: const ValueKey('host-pc'),
      icon: Icons.computer,
      title: here ? 'This PC' : 'A PC by the TV',
      children: [
        if (here) ...[
          const Hint(
            'Play right in this browser, nothing to install. The app for '
            'Windows and Mac also plays the games that do not run in a '
            'browser yet.',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const ValueKey('host-here'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: () => launchUrl(Uri.parse('$apiOrigin/play/'),
                webOnlyWindowName: '_self'),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start hosting in this browser'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('host-download'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
            ),
            onPressed: () => openWebsite(cloud, '/get'),
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download for Windows or Mac'),
          ),
        ] else ...[
          const Hint('On the PC connected to the TV, go to'),
          const SizedBox(height: 4),
          const SelectableText(
            siteAddress,
            key: ValueKey('host-address'),
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Hint(blocker == BrowserHostBlocker.browser
              ? 'This browser has no WebGPU. Use a recent Chrome, Edge, '
                  'Firefox or Safari, or download the app there.'
              : 'Play in the browser, or download the app for Windows '
                  'and Mac.'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              Builder(
                builder: (anchor) => FilledButton.icon(
                  key: const ValueKey('host-share'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: () => _share(anchor),
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Share'),
                ),
              ),
              OutlinedButton.icon(
                key: const ValueKey('host-copy'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                ),
                onPressed: () => _copy(context),
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy link'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  static final _site = Uri.parse('https://$siteAddress');

  /// The OS share sheet, to send the link to the PC (mail, chat, notes).
  /// Falls back to copying where there is no share target.
  Future<void> _share(BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox?;
    try {
      final result = await (share ?? SharePlus.instance.share)(ShareParams(
        uri: _site,
        title: 'Splitscreen Club',
        subject: 'Splitscreen Club',
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      ));
      if (result.status != ShareResultStatus.unavailable) return;
    } catch (_) {
      // No share sheet here: copy instead.
    }
    if (anchor.mounted) await _copy(anchor);
  }

  Future<void> _copy(BuildContext context) async {
    try {
      await Clipboard.setData(ClipboardData(text: _site.toString()));
      if (context.mounted) toast(context, 'Link copied');
    } catch (_) {
      if (context.mounted) toast(context, 'Select the address to copy it.');
    }
  }
}

/// "Get the app": the installer for this device first, the others after.
class GetAppScreen extends StatelessWidget {
  const GetAppScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'get-app'),
          builder: (_) => const GetAppScreen(),
        ),
      );

  /// The app is only a nudge away in a browser; the app itself has it.
  static bool get offered => kIsWeb;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Get the app')),
        body: ContentWidth(
          maxWidth: 560,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: const [
              GetTheApp(
                title: 'Splitscreen Club, a tap away',
                text: 'On your phone it is your controller and your player, '
                    'ready when you walk in. On the PC by the TV it hosts every '
                    'game in the store and updates itself.',
              ),
            ],
          ),
        ),
      );
}
