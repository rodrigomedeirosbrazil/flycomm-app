import 'package:flutter/material.dart';

/// Apertar e segurar. Grande de propósito: é operado em voo, às vezes de luva.
class PttButton extends StatefulWidget {
  const PttButton({
    super.key,
    required this.onPress,
    required this.onRelease,
    this.enabled = true,
  });

  final Future<void> Function() onPress;
  final Future<void> Function() onRelease;
  final bool enabled;

  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton> {
  bool _held = false;

  Future<void> _press() async {
    if (!widget.enabled || _held) return;
    setState(() => _held = true);
    await widget.onPress();
  }

  Future<void> _release() async {
    if (!_held) return;
    setState(() => _held = false);
    await widget.onRelease();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return GestureDetector(
      onTapDown: (_) => _press(),
      onTapUp: (_) => _release(),
      onTapCancel: _release,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 140,
        decoration: BoxDecoration(
          color: !widget.enabled
              ? colors.surfaceContainerHighest
              : _held
                  ? colors.error
                  : colors.primary,
          borderRadius: BorderRadius.circular(24),
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _held ? Icons.mic : Icons.mic_none,
              size: 44,
              color: colors.onPrimary,
            ),
            const SizedBox(height: 8),
            Text(
              _held ? 'FALANDO' : 'SEGURE PARA FALAR',
              style: TextStyle(
                color: colors.onPrimary,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
