import 'package:flutter/material.dart';

/// Page color behind grouped cards (Telegram-style settings, contacts and profile).
Color groupedBackground(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF0E1319) : const Color(0xFFF0F2F5);

/// Fill of the cards on [groupedBackground].
Color groupCardColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1A212A) : Colors.white;

/// Grey explanation under a [SettingsGroup], as in Telegram settings.
class GroupHint extends StatelessWidget {
  const GroupHint(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(28, 2, 28, 10),
        child: Text(text, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13.5, height: 1.35)),
      );
}

/// Rounded card holding a run of related rows, with an optional accent title.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Material(
        color: groupCardColor(context),
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
                  child: Text(
                    title!,
                    style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w600, fontSize: 14.5),
                  ),
                ),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}
