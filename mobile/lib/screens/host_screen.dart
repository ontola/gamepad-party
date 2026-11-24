import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// "Host a room": the TV screen can just be a browser. Starts the browser
/// host right here when this browser can run it; otherwise says where it
/// does run, with the installer as the other way.
class HostScreen extends StatelessWidget {
  final CloudApi cloud;

  /// Why this page can't be the TV screen; null when it can. Tests set it.
  final BrowserHostBlocker? blocker;
  final bool _blockerSet;

  const HostScreen({super.key, required this.cloud})
      : blocker = null,
        _blockerSet = false;

  const HostScreen.testing({
    super.key,
    required this.cloud,
    required this.blocker,
  }) : _blockerSet = true;

  static Future<void> open(BuildContext context, CloudApi cloud) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'host'),
          builder: (_) => HostScreen(cloud: cloud),
        ),
      );

  static const _steps = [
    (
      Icons.tv,
      'Open it on the TV computer',
      'Chrome, Edge or Safari on the computer that is on the TV. '
          'Nothing to install.',
    ),
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
    final play = Uri.parse('$apiOrigin/play/');
    return Scaffold(
      appBar: AppBar(title: const Text('Host a room')),
      body: ContentWidth(
        maxWidth: 560,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            const Text(
              'Play right in your browser',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            const Hint(
              'The TV shows the game, everyone plays on the couch. '
              'All you need is a browser and a few controllers.',
            ),
            const SizedBox(height: 18),
            for (final step in _steps)
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
            const SizedBox(height: 6),
            if (blocker == null)
              FilledButton.icon(
                key: const ValueKey('host-here'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: () => launchUrl(play, webOnlyWindowName: '_self'),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start hosting in this browser'),
              )
            else
              _OpenElsewhere(play: play, blocker: blocker),
            if (Apps.supported) ...[
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('host-phone'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => Apps.host(browserHost),
                icon: const Icon(Icons.cast),
                label: const Text('Host on this phone'),
              ),
              const SizedBox(height: 4),
              const Hint('Cast or mirror this phone to the TV.'),
            ],
            const SizedBox(height: 24),
            Section(
              title: 'Or install it on the TV computer',
              children: [
                const Hint(
                  'The app for Windows and Mac plays every game in the '
                  'store, also the ones that do not run in a browser yet.',
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const ValueKey('host-download'),
                    onPressed: () => openWebsite(cloud, '/get'),
                    icon: const Icon(Icons.download, size: 18),
                    label: const Text('Download for Windows or Mac'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Where the browser host runs, when it can't run here.
class _OpenElsewhere extends StatelessWidget {
  final Uri play;
  final BrowserHostBlocker blocker;
  const _OpenElsewhere({required this.play, required this.blocker});

  @override
  Widget build(BuildContext context) {
    final address = '${play.host}${play.path}'.replaceFirst(RegExp(r'/$'), '');
    return Card(
      key: const ValueKey('host-elsewhere'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'On the TV computer, go to',
              style: TextStyle(color: GnColors.muted),
            ),
            const SizedBox(height: 4),
            SelectableText(
              address,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            Hint(switch (blocker) {
              BrowserHostBlocker.browser =>
                'This browser can not run it yet. Use Chrome, Edge or Safari.',
              _ => 'A phone is too slow to be the TV screen, so open it on a '
                  'computer.',
            }),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('host-copy'),
              onPressed: () async {
                try {
                  await Clipboard.setData(ClipboardData(text: play.toString()));
                  if (context.mounted) toast(context, 'Link copied');
                } catch (_) {
                  if (context.mounted) {
                    toast(context, 'Select the address to copy it.');
                  }
                }
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy link'),
            ),
          ],
        ),
      ),
    );
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
                    'ready when you walk in. On the TV computer it hosts every '
                    'game in the store and updates itself.',
              ),
            ],
          ),
        ),
      );
}
