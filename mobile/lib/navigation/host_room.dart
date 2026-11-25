import 'package:flutter/material.dart';

import '../account.dart';
import '../screens/host_screen.dart';

/// The browser host: the Warp lobby and Luau games, in WebGPU. A phone GPU
/// is far slower than a computer's, and the adaptive quality only goes down
/// to 2/3 of the screen height (720 lines on a 1080p phone), so the phone
/// renders 3D at 540 lines.
final Uri browserHost = Uri.parse('https://splitscreen.club/play/?render=540');

/// "Host a room": a page in the app with the ways to run the TV screen:
/// this Android phone, or a PC by the TV (browser host or installer).
Future<void> hostRoom(BuildContext context, CloudApi cloud) =>
    HostScreen.open(context, cloud);

/// The label for [hostRoom]'s button.
String hostRoomLabel() => 'Host a room';
