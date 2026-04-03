import 'package:flutter/material.dart';
import 'package:flutter_muxpod/services/tmux/tmux_parser.dart';
import 'package:flutter_muxpod/theme/design_colors.dart';

/// tmuxセッションツリー表示Widget
/// 仮想スクロール対応: ListView.builder + 遅延ウィジェット生成
class SessionTree extends StatelessWidget {
  final List<TmuxSession> sessions;
  final String? selectedPaneId;
  final void Function(String paneId)? onPaneSelected;
  final void Function(String sessionName)? onSessionDoubleTap;
  final void Function(String sessionName, int windowIndex, String windowName, bool isLastWindow)? onWindowClose;

  const SessionTree({
    super.key,
    required this.sessions,
    this.selectedPaneId,
    this.onPaneSelected,
    this.onSessionDoubleTap,
    this.onWindowClose,
  });

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return const Center(
        child: Text('No tmux sessions'),
      );
    }

    return ListView.builder(
      itemCount: sessions.length,
      addAutomaticKeepAlives: false,
      addRepaintBoundaries: true,
      itemBuilder: (context, index) {
        return _SessionTile(
          session: sessions[index],
          selectedPaneId: selectedPaneId,
          onPaneSelected: onPaneSelected,
          onSessionDoubleTap: onSessionDoubleTap,
          onWindowClose: onWindowClose,
        );
      },
    );
  }
}

/// セッションタイル（展開状態を管理して遅延生成）
class _SessionTile extends StatefulWidget {
  final TmuxSession session;
  final String? selectedPaneId;
  final void Function(String paneId)? onPaneSelected;
  final void Function(String sessionName)? onSessionDoubleTap;
  final void Function(String sessionName, int windowIndex, String windowName, bool isLastWindow)? onWindowClose;

  const _SessionTile({
    required this.session,
    this.selectedPaneId,
    this.onPaneSelected,
    this.onSessionDoubleTap,
    this.onWindowClose,
  });

  @override
  State<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends State<_SessionTile> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.session.attached;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: widget.session.attached
          ? BoxDecoration(
              border: Border(
                left: BorderSide(color: colorScheme.primary, width: 3),
              ),
            )
          : null,
      child: GestureDetector(
        onDoubleTap: () => widget.onSessionDoubleTap?.call(widget.session.name),
        child: ExpansionTile(
          leading: Icon(
            Icons.folder,
            color: widget.session.attached ? colorScheme.primary : null,
          ),
          title: Text(
            widget.session.name,
            style: TextStyle(
              color: widget.session.attached ? colorScheme.primary : colorScheme.onSurface,
              fontWeight: widget.session.attached ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            '${widget.session.windowCount} windows',
            style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.38)),
          ),
          initiallyExpanded: widget.session.attached,
          onExpansionChanged: (expanded) {
            setState(() => _isExpanded = expanded);
          },
          children: _isExpanded
              ? widget.session.windows.map((window) {
                  return _WindowTile(
                    sessionName: widget.session.name,
                    window: window,
                    isLastWindow: widget.session.windows.length == 1,
                    selectedPaneId: widget.selectedPaneId,
                    onPaneSelected: widget.onPaneSelected,
                    onWindowClose: widget.onWindowClose,
                  );
                }).toList()
              : const [],
        ),
      ),
    );
  }
}

/// ウィンドウタイル（展開状態を管理して遅延生成）
class _WindowTile extends StatefulWidget {
  final String sessionName;
  final TmuxWindow window;
  final bool isLastWindow;
  final String? selectedPaneId;
  final void Function(String paneId)? onPaneSelected;
  final void Function(String sessionName, int windowIndex, String windowName, bool isLastWindow)? onWindowClose;

  const _WindowTile({
    required this.sessionName,
    required this.window,
    required this.isLastWindow,
    this.selectedPaneId,
    this.onPaneSelected,
    this.onWindowClose,
  });

  @override
  State<_WindowTile> createState() => _WindowTileState();
}

class _WindowTileState extends State<_WindowTile> {
  late bool _isExpanded;

  @override
  void initState() {
    super.initState();
    _isExpanded = widget.window.active;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      decoration: widget.window.active
          ? BoxDecoration(
              border: Border(
                left: BorderSide(color: colorScheme.primary, width: 3),
              ),
            )
          : null,
      child: Padding(
        padding: const EdgeInsets.only(left: 16),
        child: ExpansionTile(
          leading: Icon(
            Icons.tab,
            color: widget.window.active ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.6),
          ),
          title: Text(
            '${widget.window.index}: ${widget.window.name}',
            style: TextStyle(
              color: widget.window.active ? colorScheme.primary : colorScheme.onSurface,
              fontWeight: widget.window.active ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text(
            '${widget.window.paneCount} panes',
            style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.38)),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.onWindowClose != null)
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert,
                    size: 20,
                    color: colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  padding: EdgeInsets.zero,
                  itemBuilder: (menuContext) => [
                    PopupMenuItem(
                      value: 'close',
                      child: Row(
                        children: [
                          Icon(Icons.close, size: 18, color: DesignColors.error),
                          const SizedBox(width: 8),
                          Text('Close Window', style: TextStyle(color: DesignColors.error)),
                        ],
                      ),
                    ),
                  ],
                  onSelected: (value) {
                    if (value == 'close') {
                      widget.onWindowClose?.call(
                        widget.sessionName,
                        widget.window.index,
                        widget.window.name,
                        widget.isLastWindow,
                      );
                    }
                  },
                ),
              Icon(
                _isExpanded ? Icons.expand_less : Icons.expand_more,
                color: colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ],
          ),
          initiallyExpanded: widget.window.active,
          onExpansionChanged: (expanded) {
            setState(() => _isExpanded = expanded);
          },
          children: _isExpanded
              ? widget.window.panes.map((pane) {
                  return _buildPaneNode(context, pane);
                }).toList()
              : const [],
        ),
      ),
    );
  }

  Widget _buildPaneNode(BuildContext context, TmuxPane pane) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSelected = pane.id == widget.selectedPaneId;

    return Padding(
      padding: const EdgeInsets.only(left: 32),
      child: ListTile(
        leading: Icon(
          Icons.terminal,
          color: pane.active ? colorScheme.tertiary : null,
        ),
        title: Text('Pane ${pane.index}'),
        subtitle: Text('${pane.width}x${pane.height}'),
        selected: isSelected,
        selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
        onTap: () => widget.onPaneSelected?.call(pane.id),
      ),
    );
  }
}
