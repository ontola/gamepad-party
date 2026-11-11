import 'package:flutter/material.dart';

import '../app_state.dart';
import '../player_face.dart';
import '../screens/face_editor_screen.dart';
import '../theme.dart';

/// The first thing a new player sees after scanning the QR: one card with
/// two steps. Nothing happens on the TV until someone presses A on a
/// controller; then Y there picks up this phone's player, shown in step 2.
List<Widget> joinSteps(AppState state) => [
      Container(
        key: const ValueKey('press-a'),
        margin: const EdgeInsets.only(top: 8, bottom: 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2A2366), GnColors.card]),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: GnColors.accent, width: 2),
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const _Step(
            picture: Icon(Icons.sports_esports, size: 52, color: GnColors.text),
            button: _PadButton('A', Color(0xFF22A45D), Color(0xFF7CF0AE)),
            title: '1. Grab a controller and press A',
            hint: 'A player appears on the TV.',
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(color: GnColors.border, height: 1),
          ),
          _Step(
            key: const ValueKey('press-y'),
            picture: SizedBox.square(
              dimension: 52,
              child: FittedBox(
                  child:
                      PlayerFaceIcon(face: state.face, skin: state.skinColor)),
            ),
            button: const _PadButton('Y', Color(0xFFE0A100), Color(0xFFFFE08A)),
            title: '2. Press Y to pick up your player',
            hint: 'You join the TV as:',
            child: _Profile(state: state),
          ),
        ]),
      ),
    ];

class _Step extends StatelessWidget {
  final Widget picture;
  final Widget button;
  final String title;
  final String hint;
  final Widget? child;
  const _Step(
      {super.key,
      required this.picture,
      required this.button,
      required this.title,
      required this.hint,
      this.child});

  @override
  Widget build(BuildContext context) =>
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 68,
          height: 64,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned(left: 0, top: 0, child: picture),
            Positioned(right: 0, bottom: 0, child: button),
          ]),
        ),
        const SizedBox(width: 14),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 20, height: 1.2, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(hint,
                style: const TextStyle(fontSize: 14, color: GnColors.muted)),
            if (child case final child?) child,
          ]),
        ),
      ]);
}

/// This phone's player name as the TV will show it; tap to change the face.
class _Profile extends StatelessWidget {
  final AppState state;
  const _Profile({required this.state});
  @override
  Widget build(BuildContext context) => InkWell(
        key: const ValueKey('step-profile'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => FaceEditorScreen.open(context, state),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(state.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.brush, size: 16, color: GnColors.muted),
          ]),
        ),
      );
}

class _PadButton extends StatelessWidget {
  final String label;
  final Color fill;
  final Color rim;
  const _PadButton(this.label, this.fill, this.rim);
  static const size = 30.0;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fill,
          border: Border.all(color: rim, width: 2),
          boxShadow: [
            BoxShadow(
                color: fill.withValues(alpha: .4),
                blurRadius: 8,
                spreadRadius: 1)
          ],
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: size * 0.5,
                fontWeight: FontWeight.w900,
                color: Colors.white)),
      );
}

/// Once the phone has a player on the TV: this is you, and you can change
/// it right here. Stays on top of the room screen until closed.
class MeetYourPlayer extends StatefulWidget {
  final AppState state;
  const MeetYourPlayer({super.key, required this.state});

  @override
  State<MeetYourPlayer> createState() => _MeetYourPlayerState();
}

class _MeetYourPlayerState extends State<MeetYourPlayer> {
  late final _name = TextEditingController(text: widget.state.name);
  final _focus = FocusNode();

  AppState get state => widget.state;

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _editFace() async {
    await FaceEditorScreen.open(context, state);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // A name changed elsewhere (the You tab, the account) shows here too,
    // but never while typing.
    if (_name.text != state.name && !_focus.hasFocus) {
      _name.text = state.name;
    }
    return Container(
      key: const ValueKey('meet-player'),
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1F4D3E), GnColors.card]),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: GnColors.ok, width: 2),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Semantics(
          button: true,
          label: 'Edit face',
          child: GestureDetector(
            onTap: _editFace,
            child: Stack(clipBehavior: Clip.none, children: [
              Container(
                width: 96,
                height: 96,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: GnColors.field,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: FittedBox(
                    child: PlayerFaceIcon(
                        face: state.face, skin: state.skinColor)),
              ),
              const Positioned(
                right: -6,
                bottom: -6,
                child: CircleAvatar(
                  radius: 16,
                  backgroundColor: GnColors.accent,
                  child: Icon(Icons.brush, size: 16, color: Colors.white),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(
                child: Text('This is you on the TV',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              IconButton(
                key: const ValueKey('meet-player-close'),
                tooltip: 'Close',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close, size: 20),
                onPressed: state.meetPlayer,
              ),
            ]),
            const SizedBox(height: 2),
            const Text('Change your name and face. The TV updates right away.',
                style: TextStyle(fontSize: 14, color: GnColors.muted)),
            const SizedBox(height: 10),
            TextField(
              key: const ValueKey('meet-player-name'),
              controller: _name,
              focusNode: _focus,
              maxLength: 20,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                counterText: '',
                hintText: 'Your name',
                isDense: true,
                suffixIcon: Icon(Icons.edit, size: 18, color: GnColors.muted),
              ),
              onChanged: state.setName,
              onSubmitted: (_) => FocusScope.of(context).unfocus(),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonalIcon(
                onPressed: _editFace,
                icon: const Icon(Icons.brush, size: 18),
                label: const Text('Draw your face'),
              ),
              TextButton(
                onPressed: state.meetPlayer,
                child: const Text('Looks good'),
              ),
            ]),
          ]),
        ),
      ]),
    );
  }
}
