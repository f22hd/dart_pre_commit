import 'dart:collection';
import 'dart:convert';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:path/path.dart' as path;

import '../repo_entry.dart';
import '../task_base.dart';
import '../util/file_resolver.dart';
import '../util/logger.dart';
import '../util/program_runner.dart';
import 'models/analyze/analyze_result.dart';
import 'models/analyze/diagnostic.dart';
import 'provider/task_provider.dart';

part 'analyze_task.freezed.dart';
part 'analyze_task.g.dart';

// coverage:ignore-start
final analyzeTaskProvider = TaskProvider.configurable(
  AnalyzeTask._taskName,
  AnalyzeConfig.fromJson,
  (ref, config) => AnalyzeTask(
    fileResolver: ref.watch(fileResolverProvider),
    programRunner: ref.watch(programRunnerProvider),
    logger: ref.watch(taskLoggerProvider),
    config: config,
  ),
);
// coverage:ignore-end

@internal
enum AnalyzeErrorLevel {
  error(['--no-fatal-warnings']),
  warning(['--fatal-warnings']),
  info(['--fatal-warnings', '--fatal-infos']);

  final List<String> _params;

  const AnalyzeErrorLevel(this._params);
}

@internal
enum AnalysisScanMode {
  all,
  staged,
}

@internal
@freezed
class AnalyzeConfig with _$AnalyzeConfig {
  // ignore: invalid_annotation_target
  @JsonSerializable(
    anyMap: true,
    checked: true,
    disallowUnrecognizedKeys: true,
  )
  const factory AnalyzeConfig({
    // ignore: invalid_annotation_target
    @JsonKey(name: 'error-level')
    @Default(AnalyzeErrorLevel.info)
        AnalyzeErrorLevel errorLevel,
    // ignore: invalid_annotation_target
    @JsonKey(name: 'scan-mode')
    @Default(AnalysisScanMode.all)
        AnalysisScanMode scanMode,
  }) = _AnalyzeConfig;

  factory AnalyzeConfig.fromJson(Map<String, dynamic> json) =>
      _$AnalyzeConfigFromJson(json);
}

@internal
class AnalyzeTask with PatternTaskMixin implements RepoTask {
  static const _taskName = 'analyze';

  final ProgramRunner programRunner;

  final FileResolver fileResolver;

  final TaskLogger logger;

  final AnalyzeConfig config;

  const AnalyzeTask({
    required this.programRunner,
    required this.fileResolver,
    required this.logger,
    required this.config,
  });

  @override
  String get taskName => _taskName;

  @override
  Pattern get filePattern => RegExp(r'^(?:pubspec.ya?ml|.*\.dart)$');

  @override
  bool get callForEmptyEntries => false;

  @override
  Future<TaskResult> call(Iterable<RepoEntry> entries) async {
    final entriesList = entries.toList();
    if (entriesList.isEmpty) {
      throw ArgumentError('must not be empty', 'entries');
    }

    final int lintCnt;
    switch (config.scanMode) {
      case AnalysisScanMode.all:
        lintCnt = await _scanAll();
        break;
      case AnalysisScanMode.staged:
        lintCnt = await _scanStaged(entriesList);
        break;
    }

    logger.info('$lintCnt issue(s) found.');
    return lintCnt > 0 ? TaskResult.rejected : TaskResult.accepted;
  }

  Future<int> _scanAll() async {
    final result = await _runAnalyze();
    var lintCnt = 0;
    for (final diagnostic in result.diagnostics) {
      await _logDiagnostic(diagnostic);
      ++lintCnt;
    }
    return lintCnt;
  }

  Future<int> _scanStaged(List<RepoEntry> entries) async {
    final lints = HashMap<String, List<Diagnostic>>(
      equals: path.equals,
      hashCode: path.hash,
    );
    for (final entry in entries) {
      lints[entry.file.path] = <Diagnostic>[];
    }

    final result = await _runAnalyze();
    for (final diagnostic in result.diagnostics) {
      lints[diagnostic.location.file]?.add(diagnostic);
    }

    var lintCnt = 0;
    for (final entry in lints.entries) {
      if (entry.value.isNotEmpty) {
        for (final lint in entry.value) {
          ++lintCnt;
          await _logDiagnostic(lint, entry.key);
        }
      }
    }

    return lintCnt;
  }

  Future<AnalyzeResult> _runAnalyze() async {
    final jsonString = await programRunner
        .stream(
          'dart',
          [
            'analyze',
            '--format',
            'json',
            ...config.errorLevel._params,
          ],
          failOnExit: false,
        )
        .firstWhere(
          (line) => line.trimLeft().startsWith('{'),
          orElse: () => '',
        );

    if (jsonString.isEmpty) {
      return const AnalyzeResult(version: 1, diagnostics: []);
    }

    return AnalyzeResult.fromJson(
      json.decode(jsonString) as Map<String, dynamic>,
    );
  }

  Future<void> _logDiagnostic(Diagnostic diagnostic, [String? path]) async {
    final actualPath =
        path ?? await fileResolver.resolve(diagnostic.location.file);
    final loggableDiagnostic = diagnostic.copyWith(
      location: diagnostic.location.copyWith(file: actualPath),
    );
    logger.info('  $loggableDiagnostic');
  }
}
