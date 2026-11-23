import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../account.dart';
import '../apps.dart';
import '../link.dart';
import '../theme.dart';
import 'browser_host_stub.dart'
    if (dart.library.js_interop) 'browser_host_web.dart';
import 'open_website.dart';

/// The browser host: the Warp lobby and Luau games, in WebGPU. A phone GPU
/// is far slower than a computer's, and the adaptive quality only goes down
/// to 2/3 of the screen height (720 lines on a 1080p phone), so the phone
/// renders 3D at 540 lines.
final Uri browserHost = Uri.parse('https://splitscreen.club/play/?render=540');

/// "Host a room". On Android the phone can be the host itself (mirror or
/// cast it to the TV); elsewhere this is the website's page on hosting
/// from a computer. In a desktop browser that can run the browser host,
/// this browser becomes the TV screen right away.
Future<void> hostRoom(BuildContext context, CloudApi cloud) async {
  if (canHostInThisBrowser()) {
    await launchUrl(Uri.parse('$apiOrigin/play/'), webOnlyWindowName: '_self');
    return;
  }
  if (!Apps.supported) return openWebsite(cloud, '/host');
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.cast),
            title: const Text('Host on this phone'),
            subtitle: const Text(
              'Cast or mirror it to the TV',
              style: TextStyle(color: GnColors.muted),
            ),
            onTap: () => Navigator.pop(context, 'phone'),
          ),
          ListTile(
            leading: const Icon(Icons.computer),
            title: const Text('Host on a computer'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => Navigator.pop(context, 'computer'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (choice == 'phone') await Apps.host(browserHost);
  if (choice == 'computer') await openWebsite(cloud, '/host');
}

/// The label for [hostRoom]'s button.
String hostRoomLabel() =>
    canHostInThisBrowser() ? 'Host in this browser' : 'Host a room';
