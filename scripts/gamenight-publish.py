#!/usr/bin/env python3
"""Upload immutable Splitscreen Club builds and store pages using only Python's standard library."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request
import zipfile

MAX_BYTES = 512 * 1024 * 1024

def origin(value):
    u = urllib.parse.urlsplit(value)
    if (u.scheme != 'https' and not (u.scheme == 'http' and u.hostname in {'127.0.0.1', 'localhost', '::1'})) or not u.hostname or u.username or u.password or u.query or u.fragment or u.path not in {'', '/'}:
        raise ValueError('Use an HTTPS server origin (HTTP is allowed only for loopback tests)')
    return value.rstrip('/')

class HTTPError(ValueError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status

class Client:
    def __init__(self, base, token):
        self.base = origin(base)
        self.token = token
        if not token.startswith('gn_pub_'):
            raise ValueError('Set GAMENIGHT_API_TOKEN to a publishing key from the portal')

    def request(self, method, path, body=None, file=None):
        u = urllib.parse.urlsplit(self.base)
        connection = (http.client.HTTPSConnection if u.scheme == 'https' else http.client.HTTPConnection)(u.hostname, u.port, timeout=180)
        headers = {'Authorization': 'Bearer ' + self.token}
        if file:
            headers.update({'Content-Length': str(file.stat().st_size), 'Content-Type': 'application/octet-stream'})
        elif body is not None:
            body = json.dumps(body).encode()
            headers.update({'Content-Type': 'application/json', 'Content-Length': str(len(body))})
        try:
            if file:
                with file.open('rb') as stream:
                    connection.request(method, path, stream, headers)
            else:
                connection.request(method, path, body, headers)
            response = connection.getresponse()
            raw = response.read(1024 * 1024)
            try:
                result = json.loads(raw)
            except ValueError:
                result = {}
            if not 200 <= response.status < 300:
                raise HTTPError(response.status, result.get('error', f'Splitscreen Club returned HTTP {response.status}'))
            return result
        finally:
            connection.close()

    def download(self, url, destination, authenticated=True):
        u = urllib.parse.urlsplit(url)
        if authenticated and urllib.parse.urlunsplit((u.scheme, u.netloc, '', '', '')).rstrip('/') != self.base:
            raise ValueError('Refusing to send publishing credentials to another server')
        if not authenticated and (u.scheme != 'https' or u.username or u.password):
            raise ValueError('Runtime downloads require HTTPS without account credentials')
        request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + self.token} if authenticated else {})
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args):
                raise ValueError('Authenticated artifact downloads must not redirect')
        opener = urllib.request.build_opener(NoRedirect) if authenticated else urllib.request.build_opener()
        with opener.open(request, timeout=180) as response, destination.open('wb') as target:
            size = 0
            while chunk := response.read(1024 * 1024):
                size += len(chunk)
                if size > MAX_BYTES:
                    raise ValueError('Artifact exceeds 512 MiB')
                target.write(chunk)

def sha256(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()

def unpack(artifact, destination):
    with zipfile.ZipFile(artifact) as archive:
        total, names = 0, set()
        if len(archive.infolist()) > 10000:
            raise ValueError('Archive has too many entries')
        for item in archive.infolist():
            name = item.filename.rstrip('/')
            folded = name.casefold()
            if '\\' in name or ':' in name or name.startswith('/') or any(p in {'', '.', '..'} for p in name.split('/')) or (item.external_attr >> 16) & 0o170000 == 0o120000 or folded in names:
                raise ValueError('Unsafe archive')
            names.add(folded)
            total += item.file_size
            if total > 2 * 1024 * 1024 * 1024:
                raise ValueError('Archive exceeds extracted size limit')
        archive.extractall(destination)

def push(client, args):
    path = args.file.resolve()
    if not path.is_file() or path.stat().st_size > MAX_BYTES:
        raise ValueError('Provide a package no larger than 512 MiB')
    game = urllib.parse.quote(args.game, safe='')
    data = {'version': args.version, 'platform': args.platform, 'filename': path.name,
            'entrypoint': args.entrypoint, 'sha256': sha256(path),
            'changelog': args.changelog_file.read_text() if args.changelog_file else args.changelog}
    build = client.request('POST', f'/v1/developer/games/{game}/builds', data)
    if build['state'] != 'ready':
        build = client.request('PUT', f"/v1/developer/builds/{build['id']}/content", file=path)
    release = client.request('POST', f'/v1/developer/games/{game}/releases', {'build': build['id'], 'channel': args.channel})
    result = {'build_id': build['id'], 'sha256': build['sha256'], 'state': release['state'],
              'portal_url': client.base + '/developers#game/' + game}
    print(json.dumps(result, indent=2))
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            for name, value in result.items():
                output.write(f'{name}={value}\n')
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write(f"Splitscreen Club build `{build['id']}`: **{release['state']}**. [Open publishing portal]({result['portal_url']})\n")

def preview(client, args):
    feed = client.request('GET', f'/v1/developer/games/{urllib.parse.quote(args.game, safe="")}/preview-catalog')
    platform = args.platform or {'win32': 'windows', 'darwin': 'mac', 'linux': 'linux'}[sys.platform]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    shelf = []
    for entry in feed['games']:
        if platform not in entry.get('downloads', {}):
            continue
        download = entry['downloads'][platform]
        folder = output / entry['id'] / download['sha256']
        if not folder.exists():
            with tempfile.TemporaryDirectory(dir=output) as temp:
                temp = Path(temp)
                artifact = temp / 'artifact'
                client.download(download['url'], artifact)
                if sha256(artifact) != download['sha256']:
                    raise ValueError('Preview checksum mismatch')
                stage = temp / 'game'
                stage.mkdir()
                if download['url'].endswith('.zip'):
                    unpack(artifact, stage)
                else:
                    shutil.copyfile(artifact, stage / download['entrypoint'])
                executable = stage / download['entrypoint']
                if not executable.is_file():
                    raise ValueError('Missing preview executable')
                if platform != 'windows':
                    executable.chmod(executable.stat().st_mode | 0o111)
                folder.parent.mkdir(parents=True, exist_ok=True)
                stage.rename(folder)
        executable = folder / download['entrypoint']
        command, arguments = executable, []
        if runtime := download.get('runtime'):
            runtime_folder = output / '.runtimes' / runtime['sha256']
            if not runtime_folder.exists():
                with tempfile.TemporaryDirectory(dir=output) as temp:
                    temp = Path(temp)
                    artifact = temp / 'runtime.zip'
                    client.download(runtime['url'], artifact, authenticated=False)
                    if sha256(artifact) != runtime['sha256']:
                        raise ValueError('Runtime checksum mismatch')
                    stage = temp / 'runtime'
                    stage.mkdir()
                    unpack(artifact, stage)
                    binary = stage / runtime['entrypoint']
                    if not binary.is_file():
                        raise ValueError('Missing runtime executable')
                    if platform != 'windows':
                        binary.chmod(binary.stat().st_mode | 0o111)
                    runtime_folder.parent.mkdir(parents=True, exist_ok=True)
                    stage.rename(runtime_folder)
            command = runtime_folder / runtime['entrypoint']
            arguments = [str(executable if runtime.get('argument') == 'entry_point' else executable.parent)]
        shelf.append({'id': entry['id'], 'title': entry['title'], 'min_players': entry['players']['min'],
                      'max_players': entry['players']['max'], 'launch': {'command': str(command),
                      'args': arguments, 'cwd': str(executable.parent), 'env': {}},
                      **{key: entry['players'][key] for key in ('play_with', 'min_phones') if key in entry['players']}})
    if not shelf:
        raise ValueError('No preview is available for this platform')
    path = output / 'shelf.json'
    path.write_text(json.dumps(shelf, indent=2) + '\n')
    print('Preview downloaded and verified. Set GAMENIGHT_LIBRARY=' + str(path))

MEDIA = {'video': ['preview.mp4', 'preview.webm'], 'poster': ['preview.jpg', 'preview.png'],
         'cover': ['cover.png', 'cover.jpg'], 'icon': ['icon.png'],
         'screenshot': ['gameplay.png', 'screenshot.png', 'gameplay.jpg', 'screenshot.jpg']}

def store(client, args):
    manifest = json.loads(args.manifest.read_text()) if args.manifest.is_file() else {}
    game = args.game or manifest.get('id')
    if not game:
        raise ValueError('Pass --game or run next to a gamenight.json with an "id"')
    body = {k: manifest[k] for k in ('title', 'tagline', 'developer', 'tags', 'match_minutes') if k in manifest}
    players = manifest.get('players', {})
    body.update({f'players_{k}': players[k] for k in ('min', 'max') if k in players})
    body.update({k: v for k, v in manifest.get('links', {}).items() if k in ('homepage', 'source')})
    files = {}
    if args.media and args.media.is_dir():
        for field, names in MEDIA.items():
            files[field] = next((args.media / n for n in names if (args.media / n).is_file()), None)
        shots = args.media / 'screenshots'
        files['images'] = sorted(p for p in shots.iterdir() if p.suffix.lower() in {'.png', '.jpg', '.jpeg', '.webp'}) if shots.is_dir() else []
    for field in MEDIA:
        if getattr(args, field):
            files[field] = getattr(args, field)
    if args.image:
        files['images'] = args.image
    if not files.get('images') and files.get('screenshot'):
        files['images'] = [files['screenshot']]
    path = f'/v1/developer/games/{urllib.parse.quote(game, safe="")}'
    uploaded = {}
    def upload(file):
        file = file.resolve()
        if file not in uploaded:
            uploaded[file] = client.request('POST', path + '/uploads', file=file)['url']
            print(f'Uploaded {file.name}', file=sys.stderr)
        return uploaded[file]
    for field in MEDIA:
        if files.get(field):
            body[field] = upload(files[field])
    if files.get('images'):
        body['images'] = [upload(f) for f in files['images']]
    if not body:
        raise ValueError('Nothing to send: no gamenight.json fields and no media found')
    result = client.request('PUT', path + '/store', body)
    saved = args.manifest.with_name('save-schema.json')
    if saved.is_file():
        try:
            save_schema(client, game, saved)
        except HTTPError as e:
            if e.status != 404:
                raise
            print('This Splitscreen Club server does not take save schemas yet; skipped save-schema.json.', file=sys.stderr)
    print(json.dumps({'game': game, 'sent': sorted(body), **result}, indent=2))
    if not result.get('preview_ready'):
        print('The store still needs a five-second gameplay clip (preview.mp4) before it can go live.', file=sys.stderr)

CLIP_FRAMES, CLIP_FPS, CLIP_SIZE = 150, 30, (960, 540)

def clip(args):
    """Render the store clip from a recipe (preview.json), cut, encode and check it.

    The recipe is the source; the clip is rebuilt from it whenever the game
    changes, and only the clip goes to the store (with --publish), never to git.
    """
    recipe_path = args.recipe.resolve()
    recipe = json.loads(recipe_path.read_text())
    base = recipe_path.parent
    cuts = recipe.get('cuts') or []
    if sum(c['frames'] for c in cuts) != CLIP_FRAMES:
        raise ValueError(f"The cuts' frames add up to {sum(c['frames'] for c in cuts)}; a store clip is exactly {CLIP_FRAMES} (5 s at {CLIP_FPS} fps)")
    w, h = (args.render_size or recipe.get('render', '1920x1080')).split('x')
    out = (args.out or base / 'build' / 'preview').resolve()
    env = {**os.environ, **{k: str(v) for k, v in recipe.get('env', {}).items()}}
    seq = out / 'seq'
    shutil.rmtree(seq, ignore_errors=True)
    seq.mkdir(parents=True)
    n, frames_of = 0, {}
    for cut in cuts:
        folder = out / 'cuts' / cut['name']
        need = cut.get('skip', 0) + cut['frames']
        have = sorted(folder.glob('*.png')) if folder.is_dir() else []
        if not (args.reuse and len(have) >= need) and (not args.only or cut['name'] in args.only):
            shutil.rmtree(folder, ignore_errors=True)
            folder.mkdir(parents=True)
            fill = {'dir': str(folder), 'w': w, 'h': h, 'frames': str(need)}
            command = [str(a).format(**fill) for a in cut['run']]
            print(f"[{cut['name']}] {' '.join(command)}", file=sys.stderr)
            subprocess.run(command, cwd=base / cut.get('cwd', '.'), env=env, check=True)
            have = sorted(folder.glob('*.png'))
        if len(have) < need:
            raise ValueError(f"Cut {cut['name']} made {len(have)} frames, it needs {need} (skip {cut.get('skip', 0)} + {cut['frames']})")
        frames_of[cut['name']] = []
        for frame in have[cut.get('skip', 0):need]:
            target = seq / f'{n:05d}.png'
            shutil.copyfile(frame, target)
            frames_of[cut['name']].append(target)
            n += 1
    video, poster = out / 'preview.mp4', out / 'preview.jpg'
    scale = f'scale={CLIP_SIZE[0]}:{CLIP_SIZE[1]}:flags=lanczos'
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(CLIP_FPS), '-i', str(seq / '%05d.png'),
                    '-vf', scale + ',format=yuv420p', '-c:v', 'libx264', '-crf', '24', '-preset', 'slow',
                    '-color_range', 'tv', '-movflags', '+faststart', '-an', str(video)], check=True)
    at = recipe.get('poster', {})
    still = frames_of.get(at.get('cut'), frames_of[cuts[0]['name']])
    still = still[min(at.get('frame', len(still) // 2), len(still) - 1)]
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(still), '-vf', scale, '-q:v', '3', str(poster)], check=True)
    # The checks of docs/gameplay-previews.md, on the decoded clip.
    probe = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-count_frames', '-select_streams', 'v:0', '-show_entries',
                                       'stream=width,height,nb_read_frames:format=duration', '-of', 'json', str(video)],
                                      check=True, capture_output=True, text=True).stdout)
    stream = probe['streams'][0]
    hashes = subprocess.run(['ffmpeg', '-v', 'error', '-i', str(video), '-f', 'framemd5', '-'], check=True, capture_output=True, text=True).stdout
    distinct = len({line.rsplit(',', 1)[-1] for line in hashes.splitlines() if line and not line.startswith('#')})
    problems = []
    if (stream['width'], stream['height']) != CLIP_SIZE:
        problems.append(f"{stream['width']}x{stream['height']}, not {CLIP_SIZE[0]}x{CLIP_SIZE[1]}")
    if int(stream['nb_read_frames']) != CLIP_FRAMES:
        problems.append(f"{stream['nb_read_frames']} frames, not {CLIP_FRAMES}")
    if not 4.9 <= float(probe['format']['duration']) <= 5.1:
        problems.append(f"{probe['format']['duration']} s long")
    if distinct < 100:
        problems.append(f'only {distinct} distinct frames (a frozen cut?)')
    if problems:
        raise ValueError('The clip fails the store checks: ' + '; '.join(problems))
    commit = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=base, capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(['git', 'status', '--porcelain', '.'], cwd=base, capture_output=True, text=True).stdout.strip())
    provenance = {'recipe': str(recipe_path.name), 'recipe_sha256': sha256(recipe_path), 'commit': commit + ('-dirty' if dirty else ''),
                  'render': f'{w}x{h}', 'cuts': [{'name': c['name'], 'skip': c.get('skip', 0), 'frames': c['frames'], 'note': c.get('note', '')} for c in cuts],
                  'distinct_frames': distinct, 'preview.mp4': sha256(video), 'preview.jpg': sha256(poster)}
    (out / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    print(f'Clip ready: {video} and {poster} ({distinct} distinct frames). Watch it at full speed.', file=sys.stderr)
    if not args.publish:
        print('Nothing uploaded. Run again with --reuse --publish to put it in the store.', file=sys.stderr)
        return
    manifest_path = recipe_path.with_name('gamenight.json')
    game = args.game or (json.loads(manifest_path.read_text()).get('id') if manifest_path.is_file() else None)
    if not game:
        raise ValueError('Pass --game or keep the recipe next to a gamenight.json with an "id"')
    client = Client(args.server, os.environ.get('GAMENIGHT_API_TOKEN', ''))
    path = f'/v1/developer/games/{urllib.parse.quote(game, safe="")}'
    body = {field: client.request('POST', path + '/uploads', file=file)['url'] for field, file in (('video', video), ('poster', poster))}
    result = client.request('PUT', path + '/store', body)
    provenance.update(game=game, **body)
    (out / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
    print(json.dumps({'game': game, **body, 'preview_ready': result.get('preview_ready')}, indent=2))

def save_schema(client, game, file):
    """Publish save-schema.json and write save-schema.lock.json next to it."""
    path = f'/v1/developer/games/{urllib.parse.quote(game, safe="")}/save-schema'
    result = client.request('PUT', path, json.loads(file.read_text()))
    lock = file.with_name(file.name.removesuffix('.json') + '.lock.json')
    lock.write_text(json.dumps(result['lockfile'], indent=2, sort_keys=True) + '\n')
    print(f'Save schema published: {", ".join(sorted(result["fields"]))}. Commit {lock.name}.', file=sys.stderr)
    return result

def schema(client, args):
    manifest = json.loads(args.manifest.read_text()) if args.manifest.is_file() else {}
    game = args.game or manifest.get('id')
    if not game:
        raise ValueError('Pass --game or run next to a gamenight.json with an "id"')
    if not args.schema.is_file():
        raise ValueError(f'No {args.schema}: describe the data your game saves with save_player_data there')
    print(json.dumps(save_schema(client, game, args.schema)['fields'], indent=2))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--server', default='https://gamenight.ontola.io')
    commands = parser.add_subparsers(dest='command', required=True)
    p = commands.add_parser('push')
    p.add_argument('--game', required=True)
    p.add_argument('--file', type=Path, required=True)
    p.add_argument('--platform', choices=['windows', 'mac', 'linux'], required=True)
    p.add_argument('--entrypoint', required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--channel', choices=['preview', 'stable'], default='preview')
    notes = p.add_mutually_exclusive_group()
    notes.add_argument('--changelog', default='')
    notes.add_argument('--changelog-file', type=Path)
    p = commands.add_parser('preview')
    p.add_argument('--game', required=True)
    p.add_argument('--platform', choices=['windows', 'mac', 'linux'])
    p.add_argument('--output', type=Path, required=True)
    p = commands.add_parser('store', help='Fill the store page from gamenight.json and a media folder')
    p.add_argument('--game', help='Defaults to the id in gamenight.json')
    p.add_argument('--manifest', type=Path, default=Path('gamenight.json'))
    p.add_argument('--media', type=Path, default=Path('assets/gamenight'),
                   help='Folder with preview.mp4, preview.jpg, cover.png, icon.png, gameplay.png and screenshots/')
    for field in MEDIA:
        p.add_argument('--' + field, type=Path)
    p.add_argument('--image', type=Path, action='append', help='Gallery image; repeat for more')
    p = commands.add_parser('schema', help='Publish save-schema.json, the shape of what the game saves per player')
    p.add_argument('--game', help='Defaults to the id in gamenight.json')
    p.add_argument('--manifest', type=Path, default=Path('gamenight.json'))
    p.add_argument('--schema', type=Path, default=Path('save-schema.json'))
    p = commands.add_parser('clip', help='Render the five-second store clip from preview.json; --publish uploads it')
    p.add_argument('--recipe', type=Path, default=Path('preview.json'), help='Cuts: a command each that writes PNG frames into {dir}')
    p.add_argument('--out', type=Path, help='Work folder (default build/preview next to the recipe); keep it out of git')
    p.add_argument('--render-size', help='WxH for {w} and {h}, e.g. 480x270 for a quick draft')
    p.add_argument('--only', action='append', help='Render only this cut again; repeat for more')
    p.add_argument('--reuse', action='store_true', help="Keep cuts that already have their frames")
    p.add_argument('--publish', action='store_true', help='Upload the clip and poster to the store (needs GAMENIGHT_API_TOKEN)')
    p.add_argument('--game', help='Defaults to the id in the gamenight.json next to the recipe')
    args = parser.parse_args()
    if args.command == 'clip':
        return clip(args)
    client = Client(args.server, os.environ.get('GAMENIGHT_API_TOKEN', ''))
    {'push': push, 'preview': preview, 'store': store, 'schema': schema}[args.command](client, args)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, http.client.HTTPException, subprocess.CalledProcessError) as error:
        print('Splitscreen Club publishing failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
