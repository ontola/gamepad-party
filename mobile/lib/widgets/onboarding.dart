import 'package:flutter/material.dart';

import '../app_state.dart';
import '../player_face.dart';
import '../screens/face_editor_screen.dart';
import '../theme.dart';

/// The first thing a new player sees after scanning the QR: two steps of
/// the same size. Nothing happens on the TV until someone presses A on a
/// controller, then Y there picks up this phone's player, shown in step 2.
List<Widget> joinSteps(AppState state) => [
      const _StepCard(
        key: ValueKey('press-a'),
        number: 1,
        button: _PadButton('A', Color(0xFF22A45D), Color(0xFF7CF0AE)),
        title: 'Grab a controller\nand press A',
        hint: 'A player appears on the TV.',
      ),
      _StepCard(
        key: const ValueKey('press-y'),
        number: 2,
        button: const _PadButton('Y', Color(0xFFE0A100), Color(0xFFFFE08A)),
        title: 'Press Y to pick up\nyour player',
        hint: 'This one, from this phone:',
        child: _Profile(state: state),
      ),
    ];

class _StepCard extends StatelessWidget {
  final int number;
  final Widget button;
  final String title;
  final String hint;
  final Widget? child;
  const _StepCard(
      {super.key,
      required this.number,
      required this.button,
      required this.title,
      required this.hint,
      this.child});

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 8, bottom: 8),
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2A2366), GnColors.card]),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: GnColors.accent, width: 2),
        ),
        child: Column(children: [
          Row(children: [
            _StepNumber(number),
            const Spacer(),
            const Icon(Icons.sports_esports, size: 56, color: GnColors.text),
            const SizedBox(width: 12),
            button,
            const Spacer(),
            const SizedBox(width: 32),
          ]),
          const SizedBox(height: 16),
          Text(title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 28, height: 1.15, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(hint,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: GnColors.muted)),
          if (child case final child?) ...[const SizedBox(height: 12), child],
        ]),
      );
}

/// This phone's player as the TV will show it.
class _Profile extends StatelessWidget {
  final AppState state;
  const _Profile({required this.state});
  @override
  Widget build(BuildContext context) => Material(
        color: GnColors.field,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: const ValueKey('step-profile'),
          borderRadius: BorderRadius.circular(14),
          onTap: () => FaceEditorScreen.open(context, state),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
            child: Row(children: [
              SizedBox.square(
                dimension: 56,
                child: FittedBox(
                    child: PlayerFaceIcon(
                        face: state.face, skin: state.skinColor)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(state.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w800)),
              ),
              const Icon(Icons.brush, size: 18, color: GnColors.muted),
            ]),
          ),
        ),
      );
}

class _PadButton extends StatelessWidget {
  final String label;
  final Color fill;
  final Color rim;
  const _PadButton(this.label, this.fill, this.rim);
  static const size = 56.0;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fill,
          border: Border.all(color: rim, width: 3),
          boxShadow: [
            BoxShadow(
                color: fill.withValues(alpha: .4),
                blurRadius: 18,
                spreadRadius: 2)
          ],
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: size * 0.5,
                fontWeight: FontWeight.w900,
                color: Colors.white)),
      );
}

class _StepNumber extends StatelessWidget {
  final int n;
  const _StepNumber(this.n);
  @override
  Widget build(BuildContext context) => Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration:
            const BoxDecoration(shape: BoxShape.circle, color: GnColors.field),
        child: Text('$n',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
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
