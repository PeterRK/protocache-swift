#!/usr/bin/env python3
"""Run identical public benchmarks in alternating A/B order; retain raw evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', required=True, type=Path)
    parser.add_argument('--candidate', required=True, type=Path)
    parser.add_argument('--case', action='append', dest='cases')
    parser.add_argument('--rounds', type=int, default=7)
    parser.add_argument('--loops', type=int, default=300000)
    parser.add_argument('--warmup', type=int, default=1000)
    parser.add_argument('--count', type=int, default=256)
    parser.add_argument('--payload', type=int, default=0)
    parser.add_argument('--cpu', type=int)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if args.rounds < 1 or args.loops < 1 or min(args.warmup, args.count, args.payload) < 0:
        parser.error('rounds/loops must be positive; warmup/count/payload must be nonnegative')
    if args.cpu is not None:
        if not hasattr(os, 'sched_setaffinity'):
            parser.error('--cpu is supported on Linux only')
        os.sched_setaffinity(0, {args.cpu})
    binaries = {name: path.resolve() for name, path in
                [('baseline', args.baseline), ('candidate', args.candidate)]}
    cases = args.cases or ['protocache', 'protocache-ex', 'protocache-serialize',
                          'protocache-fully', 'protocache-partly', 'pc-compress']
    report = {
        'platform': platform.platform(),
        'cpu_affinity': sorted(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else None,
        'binaries': {name: {'path': str(path), 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                     for name, path in binaries.items()},
        'parameters': {key: value for key, value in vars(args).items()
                       if key not in ('baseline', 'candidate', 'output')},
        'samples': [], 'summary': {},
    }
    environment = os.environ.copy()
    fixture = args.output.resolve().with_suffix('.pc')
    if any(not case.startswith('scale-') for case in cases):
        fixture.parent.mkdir(parents=True, exist_ok=True)
        setup_environment = environment | {'PROTOCACHE_BENCH_OUTPUT': str(fixture)}
        setup_environment.pop('PROTOCACHE_BENCH_INPUT', None)
        subprocess.run([str(binaries['baseline']), '--only', 'protocache', '--loops', '1',
                        '--warmup', '0'], env=setup_environment, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        environment['PROTOCACHE_BENCH_INPUT'] = str(fixture)
        report['fixture'] = {'path': str(fixture), 'sha256': hashlib.sha256(fixture.read_bytes()).hexdigest()}
    expected = {}
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def save():
        args.output.write_text(json.dumps(report, indent=2) + '\n')

    save()
    for case in cases:
        for round_index in range(args.rounds):
            order = ['baseline', 'candidate'] if round_index % 2 == 0 else ['candidate', 'baseline']
            for variant in order:
                command = [str(binaries[variant]), '--only', case, '--loops', str(args.loops),
                           '--warmup', str(args.warmup), '--count', str(args.count),
                           '--payload', str(args.payload)]
                result = subprocess.run(command, text=True, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, timeout=600, env=environment)
                sample = {'case': case, 'round': round_index + 1, 'variant': variant,
                          'command': command, 'returncode': result.returncode, 'stdout': result.stdout}
                report['samples'].append(sample)
                save()
                if result.returncode:
                    raise RuntimeError(f'{variant} {case} failed:\n{result.stdout}')
                measurements = [json.loads(line.removeprefix('measurement '))
                                for line in result.stdout.splitlines() if line.startswith('measurement ')]
                if not measurements:
                    raise RuntimeError('binary has no machine-readable measurements; rebuild both with this driver')
                sample['measurements'] = measurements
                for measurement in measurements:
                    identity = (measurement['loops'], measurement['checksum'], measurement.get('raw_bytes'))
                    key = (case, measurement['name'])
                    if expected.setdefault(key, identity) != identity:
                        raise RuntimeError(f'size/checksum changed for {key}: {identity} != {expected[key]}')
                save()
            print(f'{case}: pair {round_index + 1}/{args.rounds}', flush=True)
        names = [m['name'] for m in measurements]
        for name in names:
            values = {variant: [m['elapsed_ns'] / m['loops']
                                for sample in report['samples']
                                if sample['case'] == case and sample['variant'] == variant
                                for m in sample['measurements'] if m['name'] == name]
                      for variant in binaries}
            baseline = statistics.median(values['baseline'])
            candidate = statistics.median(values['candidate'])
            paired_changes = [(b / a - 1) * 100 for a, b in zip(values['baseline'], values['candidate'])]
            summary = {'baseline_ns': baseline, 'candidate_ns': candidate,
                       'paired_change_percent': statistics.median(paired_changes),
                       'raw_paired_change_percent': paired_changes,
                       'change_percent': (candidate / baseline - 1) * 100,
                       'faster_pairs': sum(b < a for a, b in zip(values['baseline'], values['candidate'])),
                       'raw_ns': values}
            report['summary'][name] = summary
            print(f"{name}: {baseline:.3f} -> {candidate:.3f} ns/op "
                  f"({summary['change_percent']:+.2f}%, paired {summary['paired_change_percent']:+.2f}%, "
                  f"{summary['faster_pairs']}/{args.rounds} faster)", flush=True)
        save()


if __name__ == '__main__':
    main()
