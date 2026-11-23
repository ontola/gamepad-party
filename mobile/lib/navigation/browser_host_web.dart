import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Whether this browser can run the browser host (/play/): a computer with
/// WebGPU. Phones are too slow, and Firefox-based browsers (Firefox, Zen)
/// start WebGPU but the host's 3D passes fail there for now.
bool canHostInThisBrowser() {
  final navigator = web.window.navigator;
  final agent = navigator.userAgent;
  final phone =
      RegExp('Android|iPhone|iPad').hasMatch(agent) ||
      (navigator.platform == 'MacIntel' && navigator.maxTouchPoints > 1);
  return !phone &&
      !agent.contains('Firefox/') &&
      (navigator as JSObject).has('gpu');
}
