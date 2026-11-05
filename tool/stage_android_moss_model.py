#!/usr/bin/env python3
"""Install a pinned MOSS GGUF through the explicitly selected app identity."""
import argparse
import hashlib
from pathlib import Path
import subprocess

PACKAGE = 'dev.opensourceglasses.even_g2_r1_poc'
REVISION = '54e4bbd17da3f84adf1c1bcf7791b9b9266f741e'
MODELS = {
    'q5_k': ('6fe985fd9a9cd043728f7be49659d10de6901872dad73b49e3c30e1340582e79', 'moss-0.9b'),
    'q4_0': ('571dc83e4dd4567bcf2070151d209454be4f6396d98b590ab92dfb49cddde178', 'moss-0.9b-q4_0'),
}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def stage(device, cache, quantization='q5_k'):
    sha256, directory = MODELS[quantization]
    remote = f'files/workbench/models/{directory}/model.gguf'
    url = f'https://huggingface.co/mudler/moss-transcribe.cpp-gguf/resolve/{REVISION}/moss-transcribe-{quantization}.gguf'
    cache.mkdir(parents=True, exist_ok=True)
    model = cache / f'moss-transcribe-{quantization}.gguf'
    if not model.exists() or digest(model) != sha256:
        partial = model.with_suffix('.part')
        subprocess.run(['curl', '--fail', '--location', '--retry', '3', '--continue-at', '-',
                        '--output', str(partial), url], check=True)
        if digest(partial) != sha256:
            partial.unlink()
            raise RuntimeError('MOSS download integrity check failed.')
        partial.replace(model)
    adb = ['adb', '-s', device]
    def app(*args, **kwargs):
        return subprocess.run([*adb, 'shell', '-T', 'run-as', PACKAGE, *args],
                              check=True, capture_output=True, **kwargs)
    app('mkdir', '-p', f'files/workbench/models/{directory}')
    with model.open('rb') as stream:
        app('sh', '-c', f"'cat > {remote}.part'", stdin=stream, timeout=180)
    actual = app('sha256sum', remote + '.part').stdout.decode().split()[0]
    if actual != sha256:
        app('rm', '-f', remote + '.part')
        raise RuntimeError('MOSS device copy integrity check failed.')
    app('mv', remote + '.part', remote)
    print(f'MOSS 0.9B {quantization.upper()} installed and verified in app-private storage.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True, help='Explicit Android serial')
    parser.add_argument('--cache', type=Path, default=Path.home() / '.cache/workbench/models/moss')
    parser.add_argument('--quantization', choices=sorted(MODELS), default='q5_k')
    args = parser.parse_args()
    stage(args.device, args.cache, args.quantization)
