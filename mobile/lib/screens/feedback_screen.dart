import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../account.dart' show TableBug;
import '../reports.dart';
import '../theme.dart';
import '../voice_feedback.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen(
      {super.key,
      required this.reports,
      this.voice,
      this.initialGame,
      this.bug,
      this.bugScreenshot,
      this.onBug});
  final ReportService reports;
  final VoiceFeedback? voice;
  final String? initialGame;

  /// Describing a bug reported at the table (Back+Y, F4): no target to
  /// pick, the host's screenshot on top, and the words go to that report.
  final TableBug? bug;
  final Future<Uint8List?>? bugScreenshot;
  final Future<void> Function(String text)? onBug;

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen>
    with WidgetsBindingObserver {
  late final VoiceFeedback _voice;
  late final TextEditingController _draft;
  final _focus = FocusNode();
  String _lastVoiceText = '';
  String? _error;
  String? _lastVoiceError;
  bool _sending = false;
  bool? _delivered;
  String? _game;

  @override
  void initState() {
    super.initState();
    _voice = widget.voice ?? VoiceFeedback.instance;
    _draft = TextEditingController(
        text: widget.bug != null ? '' : widget.reports.draft);
    _game = widget.bug != null
        ? widget.bug!.game
        : widget.reports.draft.isNotEmpty
            ? widget.reports.draftGame
            : widget.initialGame ?? widget.reports.currentGame;
    _lastVoiceText = _voice.text;
    _voice.addListener(_speechChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void _speechChanged() {
    if (!mounted) return;
    if (_voice.errorCode != _lastVoiceError) {
      _lastVoiceError = _voice.errorCode;
      if (_lastVoiceError != null) {
        // Diagnostic codes only: never capture the dictated words or raw audio.
        widget.reports.captureFailure('feedback_speech: $_lastVoiceError');
      }
    }
    if (_voice.text != _lastVoiceText) {
      _lastVoiceText = _voice.text;
      final text = _voice.text.length > 6000
          ? _voice.text.substring(0, 6000)
          : _voice.text;
      _draft.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
      if (_voice.text.length > 6000) {
        _error =
            'Feedback is limited to 6,000 characters. Review your draft before sending.';
        unawaited(_voice.cancel());
      }
      _saveDraft();
    }
    setState(() {});
  }

  void _saveDraft() {
    // A bug's words belong to that report, not the feedback draft.
    if (widget.bug != null) return;
    unawaited(widget.reports
        .saveDraft(_draft.text, game: _game)
        .catchError((Object _) {
      if (mounted) {
        setState(() => _error =
            'Your draft could not be saved on this phone. Keep this page open and try sending again.');
      }
    }));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached ||
        (state == AppLifecycleState.inactive && _voice.listening)) {
      unawaited(_voice.cancel());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voice.removeListener(_speechChanged);
    unawaited(_voice.cancel());
    _draft.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    _focus.unfocus();
    setState(() => _error = null);
    if (_voice.listening) {
      await _voice.stop();
    } else {
      await _voice.start(_draft.text);
    }
  }

  Future<void> _send() async {
    if (_sending ||
        _voice.listening ||
        _voice.busy ||
        _draft.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    _focus.unfocus();
    await _voice.cancel();
    try {
      final onBug = widget.onBug;
      final delivered = onBug != null
          ? await onBug(_draft.text.trim()).then((_) => true)
          : await widget.reports
              .submitFeedback(_draft.text.trim(), game: _game);
      if (mounted) {
        setState(() {
          _delivered = delivered;
          _draft.clear();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Could not save your feedback. Your draft is still here. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final recording = _voice.listening;
    final draft = _draft.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(
          title:
              Text(widget.bug != null ? 'Describe the bug' : 'Send feedback')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _delivered != null
                ? _confirmation()
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    children: [
                      if (widget.bug != null)
                        ..._bugHeader()
                      else ...[
                        const Text('Feedback for',
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          ChoiceChip(
                              key: const ValueKey('feedback-target-club'),
                              label: const Text('Splitscreen Club'),
                              selected: _game == null,
                              onSelected: _sending || recording
                                  ? null
                                  : (_) => _pickGame(null)),
                          _gamePicker(locked: _sending || recording),
                        ]),
                        const SizedBox(height: 5),
                        Text(
                            _game == null
                                ? 'Sent to the Splitscreen Club team.'
                                : 'Sent to the developer of ${_gameTitle(_game!)}.',
                            style: const TextStyle(
                                color: GnColors.muted, fontSize: 12)),
                      ],
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                        decoration: BoxDecoration(
                          color: GnColors.card,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                              color: recording
                                  ? GnColors.accent
                                  : GnColors.border),
                        ),
                        child: Column(children: [
                          Icon(
                              recording
                                  ? Icons.graphic_eq
                                  : Icons.mic_none_rounded,
                              size: 36,
                              color: recording ? GnColors.ok : GnColors.accent),
                          const SizedBox(height: 8),
                          Semantics(
                              liveRegion: true,
                              child: Text(
                                  recording
                                      ? (_voice.finishing
                                          ? 'Finishing…'
                                          : _voice.microphoneActive
                                              ? 'Listening…'
                                              : 'Starting microphone…')
                                      : 'Talk, then review your words',
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600))),
                          if (recording) ...[
                            const SizedBox(height: 12),
                            LinearProgressIndicator(
                              key: const ValueKey('feedback-sound-level'),
                              value: _voice.soundLevel,
                              minHeight: 5,
                              semanticsLabel: 'Microphone sound level',
                              color: GnColors.ok,
                              backgroundColor: GnColors.border,
                            ),
                          ],
                          const SizedBox(height: 14),
                          SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                key: const ValueKey('feedback-record'),
                                onPressed:
                                    _sending || _voice.busy ? null : _record,
                                icon: Icon(recording
                                    ? Icons.stop_rounded
                                    : Icons.mic_rounded),
                                label: Text(_voice.busy
                                    ? 'One moment…'
                                    : recording
                                        ? 'Stop recording'
                                        : draft
                                            ? 'Continue recording'
                                            : 'Tap to talk'),
                              )),
                          TextButton.icon(
                            onPressed: _sending
                                ? null
                                : () async {
                                    await _voice.cancel();
                                    if (mounted) _focus.requestFocus();
                                  },
                            icon: const Icon(Icons.keyboard_outlined, size: 19),
                            label: const Text('Use keyboard'),
                          ),
                        ]),
                      ),
                      if (_error != null || _voice.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 14),
                          child: Semantics(
                              liveRegion: true,
                              child: Text(_error ?? _voice.error!,
                                  style: const TextStyle(
                                      color: GnColors.warn, height: 1.4))),
                        ),
                      const SizedBox(height: 18),
                      TextField(
                        key: const ValueKey('feedback-draft'),
                        controller: _draft,
                        focusNode: _focus,
                        readOnly: recording || _voice.busy || _sending,
                        minLines: 4,
                        maxLines: 9,
                        maxLength: 6000,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                            hintText: 'Your feedback…', counterText: ''),
                        onChanged: (_) {
                          _voice.invalidateResults();
                          _saveDraft();
                          setState(() => _error = null);
                        },
                      ),
                      const SizedBox(height: 12),
                      const Text(
                          'Only text is sent. No audio is stored by Splitscreen Club.',
                          style: TextStyle(
                              color: GnColors.muted,
                              fontSize: 12,
                              height: 1.5)),
                      const SizedBox(height: 14),
                      FilledButton.icon(
                        key: const ValueKey('feedback-send'),
                        onPressed:
                            !draft || recording || _voice.busy || _sending
                                ? null
                                : _send,
                        icon: _sending
                            ? const SizedBox.square(
                                dimension: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.send_rounded, size: 19),
                        label: Text(_sending ? 'Sending…' : 'Send feedback'),
                      ),
                      ExpansionTile(
                        title: const Text('What gets shared?',
                            style:
                                TextStyle(fontSize: 12, color: GnColors.muted)),
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 12),
                        children: [
                          Text(
                              'Your device’s speech service may process speech online. '
                              '${_game == null ? 'App version, current game, and recent errors are included.' : 'App version and game context are included.'} '
                              'Your unsent draft is saved on this phone.',
                              style: const TextStyle(
                                  color: GnColors.muted,
                                  fontSize: 12,
                                  height: 1.5))
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _confirmation() => Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(
              _delivered!
                  ? Icons.check_circle_outline_rounded
                  : Icons.schedule_send_rounded,
              size: 66,
              color: GnColors.ok),
          const SizedBox(height: 24),
          Text(
              _delivered!
                  ? 'Thanks for the feedback'
                  : 'Saved. We’ll send it soon.',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Text(
              _delivered! && widget.bug != null
                  ? 'Your words and the screenshot are with the people who can fix it.'
                  : _delivered!
                      ? 'Your feedback helps make the next Splitscreen Club better.'
                      : 'Your feedback is saved on this phone and will be retried when the app can connect.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: GnColors.muted, height: 1.5)),
          const SizedBox(height: 28),
          SizedBox(
              width: double.infinity,
              child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'))),
        ]),
      );

  List<Widget> _bugHeader() {
    final bug = widget.bug!;
    final title =
        bug.title ?? (bug.game != null ? _gameTitle(bug.game!) : null);
    return [
      Text(title != null ? 'Bug in $title' : 'Bug at the table',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text(
          'Someone reported a bug at the table. What went wrong? Your words go with this screenshot.',
          style: TextStyle(color: GnColors.muted, fontSize: 13, height: 1.4)),
      const SizedBox(height: 12),
      FutureBuilder<Uint8List?>(
        future: widget.bugScreenshot,
        builder: (context, shot) => shot.data == null
            ? const SizedBox.shrink()
            : ClipRRect(
                key: const ValueKey('bug-screenshot'),
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(shot.data!, fit: BoxFit.cover)),
      ),
    ];
  }

  /// Games to offer in the picker: the one this page was opened for, the
  /// game on the table and recently played games, newest first.
  List<String> get _gameChoices => {
        widget.initialGame,
        widget.reports.currentGame,
        _game,
        ...widget.reports.recentGames,
      }.whereType<String>().toList();

  void _pickGame(String? game) {
    setState(() => _game = game);
    _saveDraft();
  }

  /// One pill that opens a menu of recent games, instead of a pill per game.
  Widget _gamePicker({required bool locked}) {
    final games = _gameChoices;
    final selected = _game != null;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(GnColors.card),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: GnColors.border))),
      ),
      menuChildren: [
        for (final game in games)
          MenuItemButton(
            key: ValueKey('feedback-game-$game'),
            leadingIcon:
                Icon(game == _game ? Icons.check_rounded : null, size: 18),
            onPressed: () => _pickGame(game),
            child: Text(_gameTitle(game)),
          ),
      ],
      builder: (context, menu, _) => ChoiceChip(
        key: const ValueKey('feedback-target-game'),
        avatar: const Icon(Icons.sports_esports_outlined, size: 18),
        selected: selected,
        showCheckmark: false,
        label: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              child: Text(
                  selected
                      ? _gameTitle(_game!)
                      : games.isEmpty
                          ? 'No games played yet'
                          : 'A game',
                  overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 2),
          const Icon(Icons.arrow_drop_down_rounded, size: 20),
        ]),
        onSelected: locked || games.isEmpty
            ? null
            : (_) => menu.isOpen ? menu.close() : menu.open(),
      ),
    );
  }

  String _gameTitle(String game) => game
      .split('-')
      .map((word) =>
          word.isEmpty ? '' : '${word[0].toUpperCase()}${word.substring(1)}')
      .join(' ');
}
