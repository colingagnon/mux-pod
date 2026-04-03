import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/terminal/font_calculator.dart';
import '../services/tmux/tmux_parser.dart';
import 'settings_provider.dart';

/// ターミナル表示状態
///
/// フォントサイズ、スクロール状態、ズーム状態を管理する。
class TerminalDisplayState {
  /// ペインの横幅（文字数）
  final int paneWidth;

  /// ペインの縦幅（行数）
  final int paneHeight;

  /// 利用可能なスクリーン幅（ピクセル）
  final double screenWidth;

  /// 利用可能なスクリーン高さ（ピクセル）
  final double screenHeight;

  /// 計算されたフォントサイズ
  final double calculatedFontSize;

  /// 水平スクロールが必要か
  final bool needsHorizontalScroll;

  /// 水平スクロール位置
  final double horizontalScrollOffset;

  /// ピンチズーム倍率（1.0 = 等倍）
  final double zoomScale;

  /// ズーム操作中か
  final bool isZooming;

  const TerminalDisplayState({
    this.paneWidth = 80,
    this.paneHeight = 24,
    this.screenWidth = 0.0,
    this.screenHeight = 0.0,
    this.calculatedFontSize = 14.0,
    this.needsHorizontalScroll = false,
    this.horizontalScrollOffset = 0.0,
    this.zoomScale = 1.0,
    this.isZooming = false,
  });

  /// 実際に適用されるフォントサイズ
  double get effectiveFontSize {
    if (isZooming) {
      return calculatedFontSize * zoomScale;
    }
    return calculatedFontSize;
  }

  TerminalDisplayState copyWith({
    int? paneWidth,
    int? paneHeight,
    double? screenWidth,
    double? screenHeight,
    double? calculatedFontSize,
    bool? needsHorizontalScroll,
    double? horizontalScrollOffset,
    double? zoomScale,
    bool? isZooming,
  }) {
    return TerminalDisplayState(
      paneWidth: paneWidth ?? this.paneWidth,
      paneHeight: paneHeight ?? this.paneHeight,
      screenWidth: screenWidth ?? this.screenWidth,
      screenHeight: screenHeight ?? this.screenHeight,
      calculatedFontSize: calculatedFontSize ?? this.calculatedFontSize,
      needsHorizontalScroll: needsHorizontalScroll ?? this.needsHorizontalScroll,
      horizontalScrollOffset: horizontalScrollOffset ?? this.horizontalScrollOffset,
      zoomScale: zoomScale ?? this.zoomScale,
      isZooming: isZooming ?? this.isZooming,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalDisplayState &&
          runtimeType == other.runtimeType &&
          paneWidth == other.paneWidth &&
          paneHeight == other.paneHeight &&
          screenWidth == other.screenWidth &&
          screenHeight == other.screenHeight &&
          calculatedFontSize == other.calculatedFontSize &&
          needsHorizontalScroll == other.needsHorizontalScroll &&
          horizontalScrollOffset == other.horizontalScrollOffset &&
          zoomScale == other.zoomScale &&
          isZooming == other.isZooming;

  @override
  int get hashCode => Object.hash(
        paneWidth,
        paneHeight,
        screenWidth,
        screenHeight,
        calculatedFontSize,
        needsHorizontalScroll,
        horizontalScrollOffset,
        zoomScale,
        isZooming,
      );
}

/// ターミナル表示状態を管理するNotifier
class TerminalDisplayNotifier extends Notifier<TerminalDisplayState> {
  /// 最大フォントサイズ
  static const double maxFontSize = 48.0;

  @override
  TerminalDisplayState build() => const TerminalDisplayState();

  /// ペイン情報を更新
  ///
  /// ペイン選択時に呼び出し、フォントサイズを再計算する。
  void updatePane(TmuxPane pane) {
    // ズーム状態をリセット
    state = state.copyWith(
      paneWidth: pane.width,
      paneHeight: pane.height,
      zoomScale: 1.0,
      isZooming: false,
      horizontalScrollOffset: 0.0, // スクロール位置もリセット
    );
    _recalculateFontSize();
  }

  /// スクリーン幅を更新
  ///
  /// LayoutBuilder から呼び出される。
  void updateScreenWidth(double width) {
    if (state.screenWidth == width) return; // 変更なしなら何もしない
    state = state.copyWith(screenWidth: width);
    _recalculateFontSize();
  }

  /// スクリーンサイズを更新
  ///
  /// LayoutBuilder から幅と高さの両方を更新する。
  void updateScreenSize(double width, double height) {
    state = state.copyWith(screenWidth: width, screenHeight: height);
    _recalculateFontSize();
    _updateScrollRequirement();
  }

  /// 水平スクロール位置を更新
  void updateHorizontalScrollOffset(double offset) {
    state = state.copyWith(horizontalScrollOffset: offset);
  }

  /// ピンチズーム開始
  void startZoom() {
    state = state.copyWith(isZooming: true);
  }

  /// ピンチズーム更新
  void updateZoom(double scale) {
    state = state.copyWith(zoomScale: scale);
  }

  /// ピンチズーム終了
  ///
  /// ズーム後のフォントサイズを確定し、スケールをリセットする。
  void endZoom() {
    final settings = ref.read(settingsProvider);
    final newFontSize = state.calculatedFontSize * state.zoomScale;

    state = state.copyWith(
      calculatedFontSize: newFontSize.clamp(settings.minFontSize, maxFontSize),
      zoomScale: 1.0,
      isZooming: false,
    );

    // 水平スクロールの必要性を再計算
    _updateScrollRequirement();
  }

  /// フォントサイズを再計算
  void _recalculateFontSize() {
    final settings = ref.read(settingsProvider);

    final result = FontCalculator.calculate(
      screenWidth: state.screenWidth,
      paneCharWidth: state.paneWidth,
      fontFamily: settings.fontFamily,
      minFontSize: settings.minFontSize,
    );

    state = state.copyWith(
      calculatedFontSize: result.fontSize,
      needsHorizontalScroll: result.needsScroll,
    );
  }

  /// 水平スクロールの必要性を更新
  void _updateScrollRequirement() {
    final settings = ref.read(settingsProvider);
    final terminalWidth = FontCalculator.calculateTerminalWidth(
      paneCharWidth: state.paneWidth,
      fontSize: state.calculatedFontSize,
      fontFamily: settings.fontFamily,
    );

    state = state.copyWith(
      needsHorizontalScroll: terminalWidth > state.screenWidth,
    );
  }

  /// 設定変更時に再計算を強制
  void onSettingsChanged() {
    _recalculateFontSize();
  }
}

/// ターミナル表示プロバイダー
final terminalDisplayProvider =
    NotifierProvider<TerminalDisplayNotifier, TerminalDisplayState>(
  () => TerminalDisplayNotifier(),
);
