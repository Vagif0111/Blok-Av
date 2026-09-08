import 'dart:math';

import 'package:flutter/material.dart';
import 'package:vibration/vibration.dart';

import '../game/managers/settings_manager.dart';
import '../game/managers/storage_manager.dart';
import 'overlays/level_complete_overlay.dart';
import 'overlays/pause_overlay.dart';

class _CubeColorInfo {
  const _CubeColorInfo(this.color, this.label);
  final Color color;
  final String label;
}

const List<_CubeColorInfo> _palette = [
  _CubeColorInfo(Color(0xFFE74C3C), 'Kırmızı'),
  _CubeColorInfo(Color(0xFF3498DB), 'Mavi'),
  _CubeColorInfo(Color(0xFF2ECC71), 'Yeşil'),
  _CubeColorInfo(Color(0xFFF1C40F), 'Sarı'),
  _CubeColorInfo(Color(0xFF9B59B6), 'Mor'),
  _CubeColorInfo(Color(0xFF1ABC9C), 'Turkuaz'),
];

class _Cube {
  _Cube({
    required this.layer,
    required this.row,
    required this.col,
    required this.color,
  });
  final int layer;
  final int row;
  final int col;
  Color color;
  bool removed = false;
}

class _Mission {
  _Mission({required this.color, required this.label, required this.target});
  final Color color;
  final String label;
  final int target;
  int progress = 0;
  bool get isComplete => progress >= target;
}

enum _Status { playing, paused, levelComplete }

/// Blok toplama bulmacası: izometrik piramit şeklinde dizilmiş renkli
/// küpler. Bir küp ancak üzerinde başka küp kalmadıysa toplanabilir.
/// Görevler üstte gösterilir; hepsi tamamlanınca seviye biter.
class GameScreen extends StatefulWidget {
  const GameScreen({super.key});

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  static const double _tileWidth = 46;
  static const double _tileHeight = 23;
  static const double _cubeDepth = 22;

  final Random _random = Random();

  int _level = 1;
  int _n = 3; // piramidin taban boyutu (n x n)
  late List<List<List<_Cube?>>> _grid; // _grid[layer][row][col]
  late List<_Cube> _allCubes;
  late List<_Mission> _missions;

  final List<_Cube> _removalHistory = [];

  int _undoCount = 3;
  int _shuffleCount = 3;
  int _bombCount = 3;
  bool _bombArmed = false;

  int _bestLevel = 1;

  _Status _status = _Status.playing;

  @override
  void initState() {
    super.initState();
    _bestLevel = StorageManager.instance.highScore;
    if (_bestLevel < 1) _bestLevel = 1;
    _level = _bestLevel;
    _generateLevel();
  }

  void _generateLevel() {
    _n = (2 + _level).clamp(3, 7);

    final shuffledPalette = List<_CubeColorInfo>.from(_palette)..shuffle(_random);
    final missionColors = shuffledPalette.take(4).toList();

    final cubes = <_Cube>[];
    for (int k = 0; k < _n; k++) {
      final size = _n - k;
      for (int r = 0; r < size; r++) {
        for (int c = 0; c < size; c++) {
          cubes.add(_Cube(layer: k, row: r, col: c, color: Colors.grey));
        }
      }
    }
    cubes.shuffle(_random);
    for (int i = 0; i < cubes.length; i++) {
      cubes[i].color = missionColors[i % missionColors.length].color;
    }

    final counts = <Color, int>{};
    for (final cube in cubes) {
      counts[cube.color] = (counts[cube.color] ?? 0) + 1;
    }

    _missions = missionColors.map((info) {
      final total = counts[info.color] ?? 0;
      final ratio = 0.5 + _random.nextDouble() * 0.3;
      final target = (total * ratio).round().clamp(3, total == 0 ? 3 : total);
      return _Mission(color: info.color, label: info.label, target: target);
    }).toList();

    _grid = List.generate(_n, (k) {
      final size = _n - k;
      return List.generate(size, (r) => List.generate(size, (c) => null));
    });
    for (final cube in cubes) {
      _grid[cube.layer][cube.row][cube.col] = cube;
    }
    _allCubes = cubes;

    _removalHistory.clear();
    _undoCount = 3;
    _shuffleCount = 3;
    _bombCount = 3;
    _bombArmed = false;
    _status = _Status.playing;
  }

  bool _isExposed(int layer, int row, int col) {
    if (layer == _n - 1) return true;
    final aboveLayer = layer + 1;
    final aboveSize = _n - aboveLayer;
    for (final dr in [-1, 0]) {
      for (final dc in [-1, 0]) {
        final rr = row + dr;
        final cc = col + dc;
        if (rr >= 0 && rr < aboveSize && cc >= 0 && cc < aboveSize) {
          final above = _grid[aboveLayer][rr][cc];
          if (above != null && !above.removed) return false;
        }
      }
    }
    return true;
  }

  _Mission? _missionFor(Color color) {
    for (final m in _missions) {
      if (m.color == color) return m;
    }
    return null;
  }

  void _vibrate(int duration) {
    if (!SettingsManager.instance.vibrationEnabled) return;
    Vibration.hasVibrator().then((has) {
      if (has == true) Vibration.vibrate(duration: duration);
    });
  }

  void _onCubeTap(_Cube cube) {
    if (_status != _Status.playing) return;
    if (cube.removed) return;

    if (_bombArmed) {
      _removeCube(cube);
      _bombCount--;
      _bombArmed = false;
      _vibrate(50);
      return;
    }

    if (!_isExposed(cube.layer, cube.row, cube.col)) return;
    _removeCube(cube);
    _vibrate(20);
  }

  void _removeCube(_Cube cube) {
    setState(() {
      cube.removed = true;
      _removalHistory.add(cube);
      final mission = _missionFor(cube.color);
      if (mission != null && mission.progress < mission.target) {
        mission.progress++;
      }
      if (_missions.every((m) => m.isComplete)) {
        _status = _Status.levelComplete;
        _bestLevel = _level;
        StorageManager.instance.submitScore(_bestLevel);
        _vibrate(120);
      }
    });
  }

  void _undo() {
    if (_status != _Status.playing) return;
    if (_undoCount <= 0 || _removalHistory.isEmpty) return;
    setState(() {
      final cube = _removalHistory.removeLast();
      cube.removed = false;
      final mission = _missionFor(cube.color);
      if (mission != null && mission.progress > 0) mission.progress--;
      _undoCount--;
    });
  }

  void _shuffleRemaining() {
    if (_status != _Status.playing) return;
    if (_shuffleCount <= 0) return;
    setState(() {
      final remaining = _allCubes.where((c) => !c.removed).toList();
      final colors = remaining.map((c) => c.color).toList()..shuffle(_random);
      for (int i = 0; i < remaining.length; i++) {
        remaining[i].color = colors[i];
      }
      _shuffleCount--;
      _bombArmed = false;
    });
  }

  void _armBomb() {
    if (_status != _Status.playing) return;
    if (_bombCount <= 0) return;
    setState(() => _bombArmed = !_bombArmed);
  }

  void _pause() {
    if (_status != _Status.playing) return;
    setState(() => _status = _Status.paused);
  }

  void _resume() {
    setState(() => _status = _Status.playing);
  }

  void _restartLevel() {
    setState(_generateLevel);
  }

  void _nextLevel() {
    setState(() {
      _level++;
      _generateLevel();
    });
  }

  Offset _cubeAnchor(_Cube cube, Size canvasSize) {
    final m = (_n - cube.layer).toDouble();
    final rC = cube.row - (m - 1) / 2.0;
    final cC = cube.col - (m - 1) / 2.0;
    final originX = canvasSize.width / 2;
    final originY = canvasSize.height * 0.42;
    final x = originX + (cC - rC) * (_tileWidth / 2);
    final y = originY + (cC + rC) * (_tileHeight / 2) - cube.layer * _cubeDepth;
    return Offset(x, y);
  }

  Rect _cubeHitRect(_Cube cube, Size canvasSize) {
    final anchor = _cubeAnchor(cube, canvasSize);
    return Rect.fromLTWH(
      anchor.dx - _tileWidth / 2,
      anchor.dy - _tileHeight / 2,
      _tileWidth,
      _tileHeight + _cubeDepth,
    );
  }

  void _handleTapAt(Offset position, Size canvasSize) {
    for (int k = _n - 1; k >= 0; k--) {
      for (final cube in _grid[k].expand((row) => row)) {
        if (cube == null || cube.removed) continue;
        if (_cubeHitRect(cube, canvasSize).contains(position)) {
          _onCubeTap(cube);
          return;
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0E1A),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  _TopBar(level: _level, onPause: _pause),
                  const SizedBox(height: 8),
                  _MissionBar(missions: _missions),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final canvasSize =
                            Size(constraints.maxWidth, constraints.maxHeight);
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (details) =>
                              _handleTapAt(details.localPosition, canvasSize),
                          child: CustomPaint(
                            size: canvasSize,
                            painter: _PyramidPainter(
                              n: _n,
                              grid: _grid,
                              anchorOf: (cube) => _cubeAnchor(cube, canvasSize),
                              tileWidth: _tileWidth,
                              tileHeight: _tileHeight,
                              cubeDepth: _cubeDepth,
                              isExposed: _isExposed,
                              bombArmed: _bombArmed,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  _PowerUpBar(
                    undoCount: _undoCount,
                    shuffleCount: _shuffleCount,
                    bombCount: _bombCount,
                    bombArmed: _bombArmed,
                    onUndo: _undo,
                    onShuffle: _shuffleRemaining,
                    onBomb: _armBomb,
                  ),
                ],
              ),
              if (_status == _Status.paused)
                PauseOverlay(
                  onResume: _resume,
                  onRestart: _restartLevel,
                  onHome: () => Navigator.of(context).pop(),
                ),
              if (_status == _Status.levelComplete)
                LevelCompleteOverlay(
                  level: _level,
                  onNextLevel: _nextLevel,
                  onHome: () => Navigator.of(context).pop(),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.level, required this.onPause});
  final int level;
  final VoidCallback onPause;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          InkWell(
            onTap: onPause,
            borderRadius: BorderRadius.circular(24),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.35),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.pause_rounded, color: Colors.white, size: 22),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.35),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              'SEVİYE $level',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                letterSpacing: 1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MissionBar extends StatelessWidget {
  const _MissionBar({required this.missions});
  final List<_Mission> missions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: missions
            .map((m) => Expanded(child: _MissionCard(mission: m)))
            .toList(),
      ),
    );
  }
}

class _MissionCard extends StatelessWidget {
  const _MissionCard({required this.mission});
  final _Mission mission;

  @override
  Widget build(BuildContext context) {
    final progressRatio =
        mission.target == 0 ? 1.0 : (mission.progress / mission.target).clamp(0.0, 1.0);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF1B1F35),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: mission.color,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  mission.label,
                  style: const TextStyle(color: Colors.white70, fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progressRatio,
              minHeight: 6,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(mission.color),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${mission.progress} / ${mission.target}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _PowerUpBar extends StatelessWidget {
  const _PowerUpBar({
    required this.undoCount,
    required this.shuffleCount,
    required this.bombCount,
    required this.bombArmed,
    required this.onUndo,
    required this.onShuffle,
    required this.onBomb,
  });

  final int undoCount;
  final int shuffleCount;
  final int bombCount;
  final bool bombArmed;
  final VoidCallback onUndo;
  final VoidCallback onShuffle;
  final VoidCallback onBomb;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _PowerUpButton(
            icon: Icons.undo_rounded,
            label: 'Geri Al',
            count: undoCount,
            onTap: onUndo,
          ),
          _PowerUpButton(
            icon: Icons.shuffle_rounded,
            label: 'Karıştır',
            count: shuffleCount,
            onTap: onShuffle,
          ),
          _PowerUpButton(
            icon: Icons.whatshot_rounded,
            label: 'Bomba',
            count: bombCount,
            onTap: onBomb,
            highlighted: bombArmed,
          ),
        ],
      ),
    );
  }
}

class _PowerUpButton extends StatelessWidget {
  const _PowerUpButton({
    required this.icon,
    required this.label,
    required this.count,
    required this.onTap,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final int count;
  final VoidCallback onTap;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final disabled = count <= 0;
    return InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 92,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1F35),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: highlighted
                ? const Color(0xFF00F5FF)
                : Colors.white.withOpacity(0.08),
            width: highlighted ? 2 : 1,
          ),
        ),
        child: Opacity(
          opacity: disabled ? 0.4 : 1,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(icon, color: Colors.white, size: 26),
                  Positioned(
                    right: -8,
                    top: -6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00F5FF),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$count',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PyramidPainter extends CustomPainter {
  _PyramidPainter({
    required this.n,
    required this.grid,
    required this.anchorOf,
    required this.tileWidth,
    required this.tileHeight,
    required this.cubeDepth,
    required this.isExposed,
    required this.bombArmed,
  });

  final int n;
  final List<List<List<_Cube?>>> grid;
  final Offset Function(_Cube cube) anchorOf;
  final double tileWidth;
  final double tileHeight;
  final double cubeDepth;
  final bool Function(int layer, int row, int col) isExposed;
  final bool bombArmed;

  @override
  void paint(Canvas canvas, Size size) {
    final visibleCubes = <_Cube>[];
    for (int k = 0; k < n; k++) {
      for (final row in grid[k]) {
        for (final cube in row) {
          if (cube != null && !cube.removed) visibleCubes.add(cube);
        }
      }
    }
    // Alt katmandan üst katmana, arkadan öne doğru sırala ki üstteki
    // küpler alttakilerin üzerine doğru çizilsin.
    visibleCubes.sort((a, b) {
      final ay = anchorOf(a).dy;
      final by = anchorOf(b).dy;
      return ay.compareTo(by);
    });

    for (final cube in visibleCubes) {
      final exposed = isExposed(cube.layer, cube.row, cube.col);
      _drawCube(canvas, cube, exposed);
    }
  }

  void _drawCube(Canvas canvas, _Cube cube, bool exposed) {
    final anchor = anchorOf(cube);
    final cx = anchor.dx;
    final cy = anchor.dy;
    final hw = tileWidth / 2;
    final hh = tileHeight / 2;

    final top = Offset(cx, cy - hh);
    final right = Offset(cx + hw, cy);
    final bottom = Offset(cx, cy + hh);
    final left = Offset(cx - hw, cy);

    final baseColor = exposed ? cube.color : cube.color.withOpacity(0.45);
    final topColor = _shade(baseColor, 1.25);
    final leftColor = _shade(baseColor, 0.75);
    final rightColor = _shade(baseColor, 0.9);

    final topFace = Path()
      ..moveTo(top.dx, top.dy)
      ..lineTo(right.dx, right.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..lineTo(left.dx, left.dy)
      ..close();

    final leftFace = Path()
      ..moveTo(left.dx, left.dy)
      ..lineTo(bottom.dx, bottom.dy)
      ..lineTo(bottom.dx, bottom.dy + cubeDepth)
      ..lineTo(left.dx, left.dy + cubeDepth)
      ..close();

    final rightFace = Path()
      ..moveTo(bottom.dx, bottom.dy)
      ..lineTo(right.dx, right.dy)
      ..lineTo(right.dx, right.dy + cubeDepth)
      ..lineTo(bottom.dx, bottom.dy + cubeDepth)
      ..close();

    canvas.drawPath(leftFace, Paint()..color = leftColor);
    canvas.drawPath(rightFace, Paint()..color = rightColor);
    canvas.drawPath(topFace, Paint()..color = topColor);

    final strokePaint = Paint()
      ..color = Colors.black.withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawPath(topFace, strokePaint);
    canvas.drawPath(leftFace, strokePaint);
    canvas.drawPath(rightFace, strokePaint);

    if (bombArmed && exposed) {
      canvas.drawPath(
        topFace,
        Paint()
          ..color = Colors.redAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );
    }
  }

  Color _shade(Color color, double factor) {
    final hsl = HSLColor.fromColor(color);
    final adjusted = hsl.withLightness((hsl.lightness * factor).clamp(0.0, 1.0));
    return adjusted.toColor();
  }

  @override
  bool shouldRepaint(covariant _PyramidPainter oldDelegate) => true;
}
