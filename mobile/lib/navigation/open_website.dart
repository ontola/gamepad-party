import 'package:url_launcher/url_launcher.dart';

import '../account.dart';
import '../link.dart';

/// Opens a website page in the browser, signed in like the app when it is.
Future<void> openWebsite(CloudApi cloud, String path) async {
  Uri? url;
  try {
    url = await cloud.webHandoff(path);
  } catch (_) {
    // Fall back to the plain page; it offers its own sign-in.
  }
  await launchUrl(url ?? Uri.parse('$hostedOrigin$path'));
}

/// The Splitscreen Club community on Discord.
final discordInvite = Uri.parse('https://discord.gg/c8tyuajp4Q');

/// Opens the Discord invite outside the app, so the Discord app can take it.
Future<void> openDiscord() =>
    launchUrl(discordInvite, mode: LaunchMode.externalApplication);
