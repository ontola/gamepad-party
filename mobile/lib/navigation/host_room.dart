import 'package:flutter/material.dart';

import '../account.dart';
import '../apps.dart';
import '../theme.dart';
import 'open_website.dart';

/// The browser host: the Warp lobby and Luau games, in WebGPU.
final Uri browserHost = Uri.parse('https://splitscreen.club/play/');

/// "Host a room". On Android the phone can be the host itself (mirror or
/// cast it to the TV); elsewhere this is the website's page on hosting
/// from a computer.
Future<void> hostRoom(BuildContext context, CloudApi cloud) async {
  if (!Apps.supported) return openWebsite(cloud, '/host');
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.cast),
          title: const Text('Host on this phone'),
          subtitle: const Text('Cast or mirror it to the TV',
              style: TextStyle(color: GnColors.muted)),
          onTap: () => Navigator.pop(context, 'phone'),
        ),
        ListTile(
          leading: const Icon(Icons.computer),
          title: const Text('Host on a computer'),
          trailing: const Icon(Icons.open_in_new),
          onTap: () => Navigator.pop(context, 'computer'),
        ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (choice == 'phone') await Apps.host(browserHost);
  if (choice == 'computer') await openWebsite(cloud, '/host');
}
