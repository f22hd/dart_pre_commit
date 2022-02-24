// ignore_for_file: avoid_print

import 'dart:io';

class ExitCodeException implements Exception {
  final String program;
  final int exitCode;

  ExitCodeException(this.program, this.exitCode);

  @override
  String toString() => '$program failed with exit code: $exitCode';
}

Future<void> main(List<String> args) async {
  try {
    final branch = args.isNotEmpty ? args[0] : 'stable';
    final toolPath = args.length >= 2 ? args[1] : 'tool/.flutter';

    await _exec('git', [
      'clone',
      'https://github.com/flutter/flutter.git',
      '-b',
      branch,
      toolPath
    ]);
    await _exec('$toolPath/bin/flutter', const ['doctor', '-v']);

    final githubPathFile = File(Platform.environment['GITHUB_PATH']!);
    await githubPathFile.writeAsString(
      '${Platform.executable}\n$toolPath/bin\n',
      mode: FileMode.append,
      flush: true,
      encoding: systemEncoding,
    );
  } on ExitCodeException catch (e) {
    print(e);
    exitCode = e.exitCode;
  }
}

Future<void> _exec(String program, List<String> args) async {
  print("::debug::Running $program ${args.join(' ')}");
  final proc = await Process.start(
    program,
    args,
    mode: ProcessStartMode.inheritStdio,
  );
  final exitCode = await proc.exitCode;
  if (exitCode != 0) {
    throw ExitCodeException(program, exitCode);
  }
}
