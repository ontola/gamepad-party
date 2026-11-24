import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/storage/phone_store.dart';

ChatEntry _entry(String role, int seconds, {bool? ok}) => ChatEntry(
    key: '$role$seconds',
    role: role,
    text: '$role at $seconds',
    at: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
    ok: ok);

void main() {
  test('chat entries read the store JSON', () {
    final e = ChatEntry.fromJson({
      'key': 'k',
      'role': 'assistant',
      'text': 'Done',
      'at': 1500,
      'ok': true
    });
    expect(e.mine, isFalse);
    expect(e.ok, isTrue);
    expect(e.at.millisecondsSinceEpoch, 1500);
    expect(ChatEntry.fromJson({'text': 'hi'}).mine, isTrue);
  });

  test('an answer\'s version is the game just before the next message', () {
    final chat = [
      _entry('user', 10),
      _entry('assistant', 40, ok: true),
      _entry('user', 100),
      _entry('assistant', 130, ok: true),
    ];
    // After the first answer: up to the second before the next question.
    expect(versionAfter(chat, 1)!.millisecondsSinceEpoch, 99 * 1000);
    // The newest answer is how the game is now.
    expect(versionAfter(chat, 3), isNull);
    // Going back writes a note first: the newest answer gets a version too.
    chat.add(_entry('assistant', 200, ok: true));
    expect(versionAfter(chat, 3)!.millisecondsSinceEpoch, 199 * 1000);
  });
}
