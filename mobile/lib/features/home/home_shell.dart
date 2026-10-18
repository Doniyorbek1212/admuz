import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/formatters.dart';
import '../../l10n/strings.dart';
import '../../state/providers.dart';
import '../../widgets/common.dart';
import '../business/profile_sharing.dart';
import '../contacts/contacts_screen.dart';
import '../profile/my_profile_tab.dart';
import '../hub/hub_tab.dart';
import 'home_drawer.dart';
import 'home_screen.dart';

/// Outer scaffold of the phone layout; the chat list opens the drawer here so it covers the bottom bar.
final homeShellScaffoldKey = GlobalKey<ScaffoldState>();

/// Phone layout: chats, the hub, contacts and profile behind a floating bottom bar.
/// Wide windows keep the split view without the bar.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) askProfileSharingOnce(context, ref);
    });
  }

  /// Tabs are built on first visit, then kept alive.
  final Set<int> _visited = {0};

  void _select(int index) => setState(() {
        _index = index;
        _visited.add(index);
      });

  static const _tabs = <Widget>[
    HomeScreen(inShell: true),
    HubTab(),
    ContactsScreen(),
    MyProfileTab(),
  ];

  @override
  Widget build(BuildContext context) {
    // Keeps the shared server profile (if the user agreed) in step with Telegram.
    ref.listen(meProvider, (previous, me) {
      if (me != null && (previous == null || profileOf(previous).toJson().toString() != profileOf(me).toJson().toString())) {
        syncSharedProfile(ref, me);
      }
    });
    if (MediaQuery.sizeOf(context).width >= splitViewMinWidth) return const HomeScreen();
    return PopScope(
      // Back from another tab returns to the chats first.
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _select(0);
      },
      child: Scaffold(
        key: homeShellScaffoldKey,
        drawer: const HomeDrawer(),
        extendBody: true,
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < _tabs.length; i++) _visited.contains(i) ? _tabs[i] : const SizedBox.shrink(),
          ],
        ),
        bottomNavigationBar: _BottomBar(index: _index, onSelect: _select),
      ),
    );
  }
}

class _BottomBar extends ConsumerWidget {
  const _BottomBar({required this.index, required this.onSelect});

  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = context.s;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final me = ref.watch(meProvider);
    final unread = ref.watch(unreadCountProvider('main'));
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(14, 0, 14, 10),
      child: Container(
        height: 64,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: dark ? const Color(0xF21E2A36) : const Color(0xF5FFFFFF),
          borderRadius: BorderRadius.circular(32),
          border: Border.all(color: dark ? Colors.white10 : Colors.black12, width: 0.5),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.4 : 0.12), blurRadius: 18, offset: const Offset(0, 6))],
        ),
        child: Row(
          children: [
            _BarItem(
              label: s.t('tab_chats'),
              selected: index == 0,
              onTap: () => onSelect(0),
              icon: (color) => Badge(
                isLabelVisible: unread > 0,
                label: Text(formatCount(unread)),
                child: Icon(index == 0 ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded, color: color),
              ),
            ),
            _BarItem(
              label: s.t('tab_hub'),
              selected: index == 1,
              onTap: () => onSelect(1),
              icon: (color) => Icon(index == 1 ? Icons.grid_view_rounded : Icons.grid_view_outlined, color: color),
            ),
            _BarItem(
              label: s.t('contacts'),
              selected: index == 2,
              onTap: () => onSelect(2),
              icon: (color) => Icon(index == 2 ? Icons.account_circle_rounded : Icons.account_circle_outlined, color: color),
            ),
            _BarItem(
              label: s.t('tab_profile'),
              selected: index == 3,
              onTap: () => onSelect(3),
              icon: (color) => me == null
                  ? Icon(Icons.person_rounded, color: color)
                  : Container(
                      padding: const EdgeInsets.all(1.5),
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: index == 3 ? color : Colors.transparent, width: 1.5)),
                      child: UserAvatar(userId: me.id, size: 22, showOnline: false),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({required this.label, required this.selected, required this.onTap, required this.icon});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget Function(Color color) icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected ? theme.colorScheme.primary : theme.hintColor;
    return Expanded(
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(27),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              color: selected ? theme.colorScheme.primary.withValues(alpha: 0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(27),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                icon(color),
                const SizedBox(height: 3),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 11.5, fontWeight: selected ? FontWeight.w600 : FontWeight.w500),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
