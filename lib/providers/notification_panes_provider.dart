import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/keychain/secure_storage.dart';
import '../services/ssh/ssh_client.dart';
import '../services/tmux/tmux_commands.dart';
import '../services/tmux/tmux_parser.dart';
import 'connection_provider.dart';
import 'settings_provider.dart';

/// tmuxウィンドウフラグに基づく通知ペイン情報
class AlertPane {
  final String connectionId;
  final String connectionName;
  final String host;
  final String sessionName;
  final int windowIndex;
  final String windowName;
  final Set<TmuxWindowFlag> flags;
  final String paneId;
  final int paneIndex;
  final String? currentCommand;

  const AlertPane({
    required this.connectionId,
    required this.connectionName,
    required this.host,
    required this.sessionName,
    required this.windowIndex,
    required this.windowName,
    required this.flags,
    required this.paneId,
    required this.paneIndex,
    this.currentCommand,
  });

  String get key => '$connectionId:$sessionName:$windowIndex:$paneId';

  /// ウィンドウ単位のキー（同一ウィンドウの全ペインで共通）
  String get windowKey => '$connectionId:$sessionName:$windowIndex';

  /// 最も優先度の高いフラグを取得 (bell > activity > silence)
  TmuxWindowFlag? get primaryFlag {
    if (flags.contains(TmuxWindowFlag.bell)) return TmuxWindowFlag.bell;
    if (flags.contains(TmuxWindowFlag.activity)) return TmuxWindowFlag.activity;
    if (flags.contains(TmuxWindowFlag.silence)) return TmuxWindowFlag.silence;
    return null;
  }
}

/// 通知ペイン一覧の状態
class AlertPanesState {
  final List<AlertPane> alertPanes;
  final bool isLoading;
  final String? error;

  const AlertPanesState({
    this.alertPanes = const [],
    this.isLoading = false,
    this.error,
  });

  AlertPanesState copyWith({
    List<AlertPane>? alertPanes,
    bool? isLoading,
    String? error,
  }) {
    return AlertPanesState(
      alertPanes: alertPanes ?? this.alertPanes,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// 通知ペイン一覧を管理するNotifier
class AlertPanesNotifier extends Notifier<AlertPanesState> {
  static const _alertFlags = {
    TmuxWindowFlag.activity,
    TmuxWindowFlag.bell,
    TmuxWindowFlag.silence,
  };

  @override
  AlertPanesState build() {
    return const AlertPanesState();
  }

  /// アラートをローカルリストから除去
  void dismiss(String key) {
    final updated = state.alertPanes.where((a) => a.key != key).toList();
    state = state.copyWith(alertPanes: updated);
  }

  /// tmux側のウィンドウフラグをクリア（select-windowで当該ウィンドウを選択→元に戻す）
  Future<void> clearWindowFlag(AlertPane alert) async {
    final connectionsState = ref.read(connectionsProvider);
    final connection = connectionsState.connections
        .where((c) => c.id == alert.connectionId)
        .firstOrNull;
    if (connection == null) return;

    try {
      final storage = SecureStorageService();
      SshConnectOptions options;
      if (connection.authMethod == 'key' && connection.keyId != null) {
        final privateKey = await storage.getPrivateKey(connection.keyId!);
        final passphrase = await storage.getPassphrase(connection.keyId!);
        options = SshConnectOptions(privateKey: privateKey, passphrase: passphrase, tmuxPath: connection.tmuxPath);
      } else {
        final password = await storage.getPassword(connection.id);
        options = SshConnectOptions(password: password, tmuxPath: connection.tmuxPath);
      }

      final sshClient = SshClient();
      await sshClient.connect(
        host: connection.host,
        port: connection.port,
        username: connection.username,
        options: options,
      );

      // 当該ウィンドウを選択してtmuxの生フラグ（!,#,~）をクリア
      await sshClient.exec(
        TmuxCommands.selectWindow(alert.sessionName, alert.windowIndex),
      );

      // 永続アラートマーカー（@muxpod_alert ユーザーオプション）もクリア
      // tmuxの生フラグは他クライアントがcurrentにしているとすぐ消えるが、
      // ユーザーオプションは明示的に消さない限り残る
      await sshClient.exec(
        TmuxCommands.clearMuxpodAlert(alert.sessionName, alert.windowIndex),
      );

      await sshClient.disconnect();
    } catch (e) {
      debugPrint('Failed to clear window flag: $e');
    }
  }

  /// 現在のアラートをすべて一括クリアする
  ///
  /// 接続ごとにSSHセッションを1回だけ開き、その接続の全対象ウィンドウに対して
  /// select-window と @muxpod_alert のクリアをまとめて実行する。
  /// 個別クリアと同じ結果になるが、N回のハンドシェイクを避けて高速。
  Future<void> clearAll() async {
    final alerts = state.alertPanes;
    if (alerts.isEmpty) return;

    // まずローカル状態を即座にクリア（UIの反応を良くする）
    state = state.copyWith(alertPanes: const []);

    // 接続IDでグルーピング
    final byConnection = <String, List<AlertPane>>{};
    for (final alert in alerts) {
      byConnection.putIfAbsent(alert.connectionId, () => []).add(alert);
    }

    final connectionsState = ref.read(connectionsProvider);
    final storage = SecureStorageService();

    for (final entry in byConnection.entries) {
      final connection = connectionsState.connections
          .where((c) => c.id == entry.key)
          .firstOrNull;
      if (connection == null) continue;

      // 同じウィンドウに複数ペインのアラートがあっても1回だけクリアするため重複除去
      final uniqueWindows = <String, AlertPane>{};
      for (final alert in entry.value) {
        uniqueWindows[alert.windowKey] = alert;
      }

      try {
        SshConnectOptions options;
        if (connection.authMethod == 'key' && connection.keyId != null) {
          final privateKey = await storage.getPrivateKey(connection.keyId!);
          final passphrase = await storage.getPassphrase(connection.keyId!);
          options = SshConnectOptions(privateKey: privateKey, passphrase: passphrase, tmuxPath: connection.tmuxPath);
        } else {
          final password = await storage.getPassword(connection.id);
          options = SshConnectOptions(password: password, tmuxPath: connection.tmuxPath);
        }

        final sshClient = SshClient();
        await sshClient.connect(
          host: connection.host,
          port: connection.port,
          username: connection.username,
          options: options,
        );

        // 対象ウィンドウそれぞれに対して select-window と @muxpod_alert 解除を流す
        for (final alert in uniqueWindows.values) {
          await sshClient.exec(
            TmuxCommands.selectWindow(alert.sessionName, alert.windowIndex),
          );
          await sshClient.exec(
            TmuxCommands.clearMuxpodAlert(alert.sessionName, alert.windowIndex),
          );
        }

        await sshClient.disconnect();
      } catch (e) {
        debugPrint('Failed to clear alerts for ${connection.name}: $e');
      }
    }
  }

  /// 全接続からアラートペインを取得
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null);

    final connectionsState = ref.read(connectionsProvider);
    final connections = connectionsState.connections;
    final storage = SecureStorageService();
    final allAlertPanes = <AlertPane>[];

    for (final connection in connections) {
      try {
        SshConnectOptions options;
        if (connection.authMethod == 'key' && connection.keyId != null) {
          final privateKey = await storage.getPrivateKey(connection.keyId!);
          final passphrase = await storage.getPassphrase(connection.keyId!);
          options = SshConnectOptions(privateKey: privateKey, passphrase: passphrase, tmuxPath: connection.tmuxPath);
        } else {
          final password = await storage.getPassword(connection.id);
          options = SshConnectOptions(password: password, tmuxPath: connection.tmuxPath);
        }

        final sshClient = SshClient();
        await sshClient.connect(
          host: connection.host,
          port: connection.port,
          username: connection.username,
          options: options,
        );

        final persistentAlertsEnabled =
            ref.read(settingsProvider).persistentAlertsEnabled;
        final output = await sshClient.exec(TmuxCommands.listAllPanes());
        final sessions = TmuxParser.parseFullTree(
          output,
          includeMuxpodAlerts: persistentAlertsEnabled,
        );

        for (final session in sessions) {
          for (final window in session.windows) {
            final windowAlertFlags = window.flags.intersection(_alertFlags);
            if (windowAlertFlags.isEmpty) continue;
            if (window.panes.isEmpty) continue;

            // アラートはウィンドウ単位で1つだけ発行する。
            // アクティブペインがあればそれを代表ペインとして使い、
            // 無ければ最小インデックスのペインを使う。
            // タップ時の遷移先・dismissロジックはwindowKeyで同期されるため、
            // 1ウィンドウに複数ペインがあっても重複表示する必要はない。
            final representative = window.panes.firstWhere(
              (p) => p.active,
              orElse: () => (window.panes.toList()
                    ..sort((a, b) => a.index.compareTo(b.index)))
                  .first,
            );

            allAlertPanes.add(AlertPane(
              connectionId: connection.id,
              connectionName: connection.name,
              host: connection.host,
              sessionName: session.name,
              windowIndex: window.index,
              windowName: window.name,
              flags: windowAlertFlags,
              paneId: representative.id,
              paneIndex: representative.index,
              currentCommand: representative.currentCommand,
            ));
          }
        }

        await sshClient.disconnect();
      } catch (e) {
        debugPrint('Failed to fetch alert panes for ${connection.name}: $e');
      }
    }

    state = AlertPanesState(alertPanes: allAlertPanes);
  }
}

/// 通知ペインプロバイダー
final alertPanesProvider =
    NotifierProvider<AlertPanesNotifier, AlertPanesState>(() {
  return AlertPanesNotifier();
});
