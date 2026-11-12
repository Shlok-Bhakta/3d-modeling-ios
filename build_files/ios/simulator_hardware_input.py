#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Blender Authors
# SPDX-License-Identifier: GPL-2.0-or-later
"""Run real mouse HID through UIKit/GameController and assert Blender outcomes."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import signal
import tempfile
import subprocess
import time


HERE = Path(__file__).resolve().parent
CASES = ('middle', 'gizmos', 'touch', 'keyboard', 'pan', 'zoom', 'wheel', 'wheel-shift',
         'wheel-ctrl', 'wheel-shift-ctrl', 'wheel-alt', 'cursor', 'cursor-load', 'click',
         'sidebar', 'preferences', 'idle', 'button-chord', 'text-return')


def run(*args, **kwargs):
    result = subprocess.run(list(map(str, args)), text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{args[:3]} failed ({result.returncode}):\n' +
                           result.stdout + result.stderr)
    return result


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, ValueError):
        return None


def wait_for(predicate, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise RuntimeError(f'timed out waiting for {description}')


def vertical_wheel_reports(before, samples):
    reports = {}
    for sample in samples:
        # GameController's raw scroll axes rotate with the device. UIKit already
        # delivers view-oriented scrolling; normalize this independent observer
        # to the scene orientation before comparing it with Blender's events.
        axis, sign = {1: ('y', 1), 2: ('y', -1), 3: ('x', -1), 4: ('x', 1)}[
            sample['platform'].get('interface_orientation', 1)]
        for report in sample['platform'].get('scroll_events', []):
            if report['time'] >= before['t'] and report[axis] != 0:
                reports[report['sequence']] = report[axis] * sign
    return list(reports.values())


def assert_wheel_zoom(before, after, samples, expected_reports=3):
    wheel_y = vertical_wheel_reports(before, samples)
    if len(wheel_y) != expected_reports:
        raise RuntimeError(f'OS received {len(wheel_y)} of {expected_reports} wheel reports; invalid HID setup')
    # The OS may invert physical scroll deltas for Natural Scrolling. Check the
    # delivered delta, then let Blender's ordinary wheel keymap control zoom.
    direction = 1 if wheel_y[0] > 0 else -1
    assert all(y * direction > 0 for y in wheel_y), 'fixture mixed wheel directions'
    assert (after['distance'] - before['distance']) * direction < -.01, \
        'plain mouse wheel did not zoom in the expected direction'
    assert before['rotation'] == after['rotation'], 'plain mouse wheel rotated the viewport'
    assert before['view_location'] == after['view_location'], 'plain mouse wheel panned the viewport'
    event_type = 'WHEELUPMOUSE' if direction > 0 else 'WHEELDOWNMOUSE'
    wheel_events = [e['type'] for e in after['events'] if e['type'].startswith('WHEEL')]
    assert wheel_events == [event_type] * expected_reports, \
        'each wheel tick must arrive once as a native Blender wheel event'
    assert not any(e['type'] == 'TRACKPADPAN' for e in after['events']), \
        'mouse wheel also generated trackpad scrolling'
    assert before['pointer'] == after['pointer'], 'wheel moved the cursor'


def assert_modified_wheel(before, after, samples, modifiers):
    reports = vertical_wheel_reports(before, samples)
    if len(reports) != 1:
        raise RuntimeError('OS did not deliver exactly one vertical wheel report; invalid HID setup')
    wheel = [e for e in after['events'] if e['type'].startswith('WHEEL')]
    assert len(wheel) == 1, 'modified wheel did not deliver exactly one wheel event'
    expected_type = 'WHEELUPMOUSE' if reports[0] > 0 else 'WHEELDOWNMOUSE'
    assert wheel[0]['type'] == expected_type, 'modifier changed the wheel axis or direction'
    for flag in ('shift', 'ctrl', 'alt', 'oskey'):
        assert bool(wheel[0][flag]) == (flag in modifiers), f'{flag} was incorrect on the wheel event'


def exercise(app: Path, device: str, output: Path, case, kind, method, skip_install=False,
             record=False, wheel_delta=1, wheel_reports=3, modifier_side='left', orientation='default'):
    output.mkdir(parents=True, exist_ok=True)
    bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
    if record or case == 'wheel-alt':
        # Establish the headed Simulator's accessory service before connecting
        # the test mouse. Alt-scroll also needs this headed accessory service.
        run('open', '-a', 'Simulator', '--args', '-CurrentDeviceUDID', device)
    if not skip_install:
        run('xcrun', 'simctl', 'install', device, app)
    subprocess.run(['xcrun', 'simctl', 'terminate', device, bundle],
                   capture_output=True, text=True)
    container = Path(run('xcrun', 'simctl', 'get_app_container', device, bundle, 'data').stdout.strip())
    folder = container / 'tmp' / 'input-regression'
    folder.mkdir(exist_ok=True)
    state_file = folder / 'state.json'
    error_file = folder / 'error.txt'
    platform_file = container / 'tmp' / 'hardware-os.json'
    state_file.unlink(missing_ok=True)
    platform_file.unlink(missing_ok=True)
    error_file.unlink(missing_ok=True)
    (folder / 'command.json').unlink(missing_ok=True)
    helper = output / 'hardware-hid'
    run('xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'AppKit',
        HERE / 'simulator_gesture_hid.m', '-o', helper)
    observer = folder / 'hardware-observer.dylib'
    run('xcrun', '--sdk', 'iphonesimulator', 'clang', '-target',
        'arm64-apple-ios18.0-simulator', '-fobjc-arc', '-dynamiclib',
        '-framework', 'Foundation', '-framework', 'GameController', '-framework', 'UIKit',
        HERE / 'tests' / 'hardware_input_observer.m', '-o', observer)
    source = f'PROBE_DIRECTORY={str(folder)!r}\n' + (HERE / 'hardware_input_probe.py').read_text()
    environment = dict(os.environ, SIMCTL_CHILD_DYLD_INSERT_LIBRARIES=str(observer))
    if orientation == 'landscape':
        environment['SIMCTL_CHILD_BLENDER_INPUT_LANDSCAPE'] = '1'
    launch = run('xcrun', 'simctl', 'launch', '--terminate-running-process',
                 f'--stdout={folder / "app-stdout.log"}', f'--stderr={folder / "app-stderr.log"}',
                 device, bundle, '--factory-startup', '--python-exit-code', '7',
                 '--python-expr', f'exec({source!r})', env=environment, timeout=90)
    (output / 'launch.log').write_text(launch.stdout + launch.stderr)
    app_pid = int(launch.stdout.strip().rsplit(':', 1)[1])

    def ready():
        state = read_json(state_file)
        platform = read_json(platform_file)
        if platform and platform.get('geometry_error'):
            raise RuntimeError(platform['geometry_error'])
        return state if (state and state.get('pid') == app_pid and state['ticks'] > 8 and
                         (orientation != 'landscape' or state['width'] > state['height']) and
                         platform and platform.get('pid') == app_pid) else None

    before = wait_for(ready, 'Blender and the OS accessory observer', timeout=90)
    hid_environment = dict(os.environ, DEVELOPER_DIR=run('xcode-select', '-p').stdout.strip())
    if case != 'touch':
        # Wait for the OS accessory before replaying button transitions.
        run(helper, device, input=json.dumps([dict(mouse=[0, 0])]), env=hid_environment)
        wait_for(lambda: (s := read_json(platform_file)) and s['mice'], 'the OS mouse connection')

    def fresh(tick):
        def check():
            if error_file.exists():
                raise RuntimeError(error_file.read_text())
            state = read_json(state_file)
            return state if state and state['ticks'] > tick + 4 else None
        return wait_for(check, 'fresh Blender frame')

    def configure(**options):
        tick = read_json(state_file)['ticks']
        temporary = folder / 'command.new'
        temporary.write_text(json.dumps(options))
        temporary.replace(folder / 'command.json')
        wait_for(lambda: not (folder / 'command.json').exists(), 'fixture configuration')
        return fresh(tick)

    def replay(events):
        samples = []
        with (output / 'hid.log').open('w') as log:
            process = subprocess.Popen([str(helper), device, '--existing-mouse'], stdin=subprocess.PIPE,
                                       stdout=log, stderr=log, text=True, env=hid_environment)
            process.stdin.write(json.dumps(events))
            process.stdin.close()
            deadline = time.monotonic() + 45
            while process.poll() is None and time.monotonic() < deadline:
                platform = read_json(platform_file)
                state = read_json(state_file)
                if platform and state:
                    samples.append(dict(platform=platform, state=state))
                time.sleep(.05)
            if process.poll() is None:
                process.kill()
                process.wait()
                raise RuntimeError('HID helper did not finish')
            if process.returncode:
                raise RuntimeError((output / 'hid.log').read_text())
        if not samples:
            raise RuntimeError('no state samples while sending HID')
        after = fresh(samples[-1]['state']['ticks'])
        samples.append(dict(platform=read_json(platform_file), state=after))
        return after, samples

    def assert_case(name, before, events, assertion):
        after, samples = replay(events)
        result = dict(before=before, after=after, samples=samples, result='FAIL')
        try:
            assertion(before, after, samples)
            result['result'] = 'PASS'
        finally:
            (output / f'{name}.json').write_text(json.dumps(result, indent=2) + '\n')
        print(f'PASS: {name}', flush=True)
        return after

    before = configure(setup=kind, orbit_method=method, clear=True)
    center = [int(before['origin'][0]), int(before['origin'][1])]
    if case in {'gizmos', 'touch'}:
        center[0] += 190
    before = configure(warp=center, clear=True)
    if not before['pointer'] or any(abs(a-b) > 2 for a,b in zip(before['pointer'], center)):
        raise RuntimeError('virtual cursor did not reach the fixture target')

    def point_at(target):
        # A real system pointer cannot be warped by Blender. Move the HID mouse
        # to the target and observe the resulting UIKit/Blender position instead.
        if read_json(platform_file)['locked']:
            return configure(warp=target, clear=True)
        state, _ = replay([dict(mouse=[1, 1], wait=.1)])
        for _ in range(40):
            native = read_json(platform_file).get('native_pointer')
            if native is None:
                # A Blender warp is not evidence that the OS pointer arrived.
                state, _ = replay([dict(mouse=[8, 8], wait=.1)])
                continue
            position = [native[0], state['height'] - native[1]]
            dx = target[0] - position[0]
            dy = position[1] - target[1]
            if max(abs(dx), abs(dy)) <= 3:
                return configure(clear=True)
            state, _ = replay([dict(mouse=[max(-80, min(80, dx / 4)),
                                           max(-80, min(80, dy / 4))], wait=.1)])
        raise RuntimeError(f'HID mouse did not reach {target}; last position {state["pointer"]}')

    if case != 'touch':
        before = point_at(center)

    recorder = None
    recording = None
    if record:
        recording = tempfile.TemporaryDirectory(prefix='blender-input-video-', dir='/tmp')
        recorder = subprocess.Popen(['xcrun', 'simctl', 'io', device, 'recordVideo',
                                     '--codec=h264', '--force', recording.name + '/demo.mp4'],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)
    try:
        if case == 'idle':
            def idled(b, a, samples):
                assert samples[-1]['platform']['preferred_fps'] <= 30, \
                    'idle app keeps requesting maximum display callbacks'
                assert a['ticks'] > b['ticks'], 'idle pacing stopped Blender timers'
            before = configure(clear=True)
            before = assert_case('idle', before, [dict(idle=True, wait=1.5)], idled)
            after, samples = replay([dict(mouse=[1, 1], wait=.1)])
            assert samples[-1]['platform']['preferred_fps'] == samples[-1]['platform']['maximum_fps'], \
                'input did not restore the maximum display rate'
            assert after['pointer'] != before['pointer'], 'input did not move the cursor after idle'
            print('PASS: input wakes idle app', flush=True)

        elif case in {'cursor', 'cursor-load'}:
            if case == 'cursor-load':
                temporary = folder / 'command.new'
                temporary.write_text(json.dumps(dict(cycles=True)))
                temporary.replace(folder / 'command.json')
            after, samples = replay([dict(mouse=[2, 1], wait=.02) for _ in range(20)] +
                                    [dict(mouse=[-2, -1], wait=.02) for _ in range(20)])
            assert all(not s['platform']['locked'] for s in samples), \
                'ordinary pointing captures raw input and bypasses iPad tracking and acceleration'
            assert samples[-1]['platform']['raw_motion_callbacks'] == samples[0]['platform']['raw_motion_callbacks'], \
                'normal pointing still dispatches unused raw mouse callbacks on the main queue'
            if case == 'cursor':
                positions = [s['platform']['native_pointer'][0] for s in samples
                             if s['platform']['native_pointer']]
                if not positions or max(positions) - min(positions) < 10:
                    raise RuntimeError('OS pointer did not move through the fixture; invalid HID setup')
            assert samples[-1]['platform']['custom_arrow'], 'app arrow is not used for system pointing'
            native = samples[-1]['platform']['native_pointer']
            expected = [native[0], after['height'] - native[1]]
            assert max(abs(a - b) for a, b in zip(after['pointer'], expected)) <= 3, \
                'Blender hit position is out of sync with the native pointer'
            if case == 'cursor-load':
                assert after['render_engine'] == 'CYCLES' and after['shading_type'] == 'RENDERED', \
                    'load fixture did not enter the rendered Cycles viewport'
            (output / 'cursor.json').write_text(json.dumps(dict(before=before, after=after,
                                                              samples=samples, result='PASS'), indent=2))
            print('PASS: cursor uses system tracking', flush=True)

        elif case == 'button-chord':
            before = configure(preferences=True, clear=True)
            before = point_at([int(before['width'] * .5), int(before['height'] * .3)])
            after, samples = replay([dict(mouse=[0, 0], buttons=1, wait=.3),
                                     dict(mouse=[0, 0], buttons=3, wait=.3),
                                     dict(mouse=[0, 0], buttons=2, wait=.3),
                                     dict(mouse=[0, 0], wait=.3)])
            (output / 'button-chord.json').write_text(json.dumps(dict(before=before, after=after,
                                                                      samples=samples), indent=2))
            edges = [(e['type'], e['value']) for e in after['events']
                     if e['type'] in {'LEFTMOUSE', 'RIGHTMOUSE'} and e['value'] in {'PRESS', 'RELEASE'}]
            assert edges == [('LEFTMOUSE', 'PRESS'), ('RIGHTMOUSE', 'PRESS'),
                             ('LEFTMOUSE', 'RELEASE'), ('RIGHTMOUSE', 'RELEASE')], \
                f'overlapping button holds produced {edges}'
            print('PASS: overlapping button holds', flush=True)

        elif case == 'preferences':
            before = configure(preferences=True, clear=True)
            (output / 'preferences-setup.json').write_text(json.dumps(before, indent=2))
            run('xcrun', 'simctl', 'io', device, 'screenshot', '/tmp/issue58-preferences.png')
            (output / 'preferences.png').write_bytes(Path('/tmp/issue58-preferences.png').read_bytes())
            target = [int(before['width'] * .555), int(before['height'] * .96)]
            before = point_at(target)
            for index in range(3):
                def preference_clicked(b, a, samples):
                    edges = [e['value'] for e in a['events']
                             if e['type'] == 'LEFTMOUSE' and e['value'] in {'PRESS', 'RELEASE'}]
                    assert edges == ['PRESS', 'RELEASE'], f'checkbox click produced {edges}'
                    assert a['checkbox'] != b['checkbox'], 'Preferences checkbox toggled back on release'
                assert_case(f'preferences-click-{index + 1}', before,
                            [dict(mouse=[0, 0], buttons=1, wait=.4),
                             dict(mouse=[0, 0], wait=.5)], preference_clicked)
                before = configure(clear=True)
            before = point_at([int(before['width'] * .971), int(before['height'] * .979)])
            def native_close(b, a, samples):
                assert a['window_count'] == 1, 'native Preferences close button did not close the window'
                assert not any(e['type'] == 'LEFTMOUSE' and e['value'] == 'PRESS'
                               for e in a['events']), 'native close click also reached Blender'
            assert_case('native-close', before, [dict(mouse=[0, 0], buttons=1, wait=.4),
                                               dict(mouse=[0, 0], wait=.5)], native_close)

        elif case == 'text-return':
            # #69: a hardware keyboard's Return must confirm a value typed into a Blender field.
            before = configure(sidebar=True)
            before = configure(sidebar_category=True, number_field=True, clear=True)
            x, y, width, height = before['sidebar']
            before = point_at([int(x + width * .4), int(y + height - 85)])
            def key(usage):
                return [dict(key=usage, phase=1, wait=.08), dict(key=usage, phase=2, wait=.08)]
            def committed(b, a, samples):
                keys = [(e['type'], e['value']) for e in a['events']
                        if e['type'] in {'FOUR', 'TWO', 'RET'}]
                assert a['frame_end'] == 42, f'Return left End at {a["frame_end"]}; keys {keys}'
            events = [dict(mouse=[0, 0], buttons=1, wait=.4), dict(mouse=[0, 0], wait=1)]
            events += key(0x21) + key(0x1f) + [dict(mouse=[0, 0], wait=.3)] + key(0x28)
            events += [dict(mouse=[0, 0], wait=.5)]
            assert_case('text-return', before, events, committed)

        elif case in {'click', 'sidebar'}:
            before = configure(sidebar=True)
            before = configure(sidebar_category=True, clear=True)
            x, y, width, height = before['sidebar']
            target = [int(x + width * .4), int(y + height - 85)]
            before = point_at(target)
            if case == 'click':
                def clicked(b, a, samples):
                    edges = [(e['type'], e['value']) for e in a['events']
                             if e['type'] == 'LEFTMOUSE' and e['value'] in {'PRESS', 'RELEASE'}]
                    assert edges == [('LEFTMOUSE', 'PRESS'), ('LEFTMOUSE', 'RELEASE')], \
                        f'one physical click produced {edges}'
                    assert a['checkbox'] != b['checkbox'], 'checkbox did not remain toggled after release'
                assert_case('checkbox', before, [dict(mouse=[0, 0], buttons=1, wait=.4),
                                               dict(mouse=[0, 0], wait=.4)], clicked)
            else:
                def scrolled(b, a, samples):
                    assert b['sidebar_view'] != a['sidebar_view'], 'mouse wheel did not scroll the sidebar'
                    assert b['distance'] == a['distance'], 'sidebar wheel zoomed the viewport'
                assert_case('sidebar', before, [dict(wheel=[0, 1], wait=.4)], scrolled)

        elif case in {'wheel-shift', 'wheel-ctrl', 'wheel-shift-ctrl', 'wheel-alt'}:
            before = configure(clear=True)
            if case == 'wheel-shift':
                before = configure(graph_editor=True, clear=True)
                x, y, width, height = before['timeline']
                before = point_at([int(x + width / 2), int(y + height / 2)])
            elif case == 'wheel-ctrl':
                x, y, width, height = before['timeline']
                before = point_at([int(x + width / 2), int(y + height / 2)])
            modifiers = case.split('-')[1:]
            usages = {'shift': 0xe1, 'ctrl': 0xe0, 'alt': 0xe2}
            if modifier_side == 'right':
                usages = {name: usage + 4 for name, usage in usages.items()}
            events = [dict(key=usages[m], phase=1, wait=.2) for m in modifiers]
            events += [dict(wheel=[0, wheel_delta], wait=.5)]
            events += [dict(key=usages[m], phase=2, wait=.4) for m in reversed(modifiers)]
            def modified_wheel(b, a, samples):
                assert_modified_wheel(b, a, samples, modifiers)
                if case == 'wheel-shift':
                    assert b['timeline_view'][1] != a['timeline_view'][1], 'Shift-wheel did not pan the graph vertically'
                elif case == 'wheel-ctrl':
                    assert b['timeline_view'][0] != a['timeline_view'][0], 'Ctrl-wheel did not pan the timeline'
                elif case == 'wheel-alt':
                    assert abs(a['frame_current'] - b['frame_current']) == 1, 'Alt-wheel did not step the frame'
            assert_case(case, before, events, modified_wheel)

        elif case in {'wheel', 'wheel-sweep'}:
            for delta in ((1, -1, .25, -12) if case == 'wheel-sweep' else (wheel_delta,)):
                before = configure(setup=kind, clear=True)
                events = [dict(wheel=[0, delta], wait=.8) for _ in range(wheel_reports)]
                assert_case(f'wheel-{delta}', before, events,
                            lambda b, a, s: assert_wheel_zoom(b, a, s, expected_reports=wheel_reports))

        elif case == 'middle':
            def orbit_assertion(before, after, samples):
                presses = sum(e['type'] == 'MIDDLEMOUSE' and e['value'] == 'PRESS'
                              for e in after['events'])
                os_presses = 0
                was_down = False
                for sample in samples:
                    down = any(m['middle'] for m in sample['platform']['mice'])
                    os_presses += down and not was_down
                    was_down = down
                if os_presses < 1:
                    raise RuntimeError('OS did not receive the middle press; invalid HID setup')
                assert presses >= 1, 'Blender did not receive the middle-button press'
                assert before['rotation'] != after['rotation'], \
                    'middle-button drags did not rotate the viewport'
            drag = ([dict(mouse=[0, 0], buttons=4, wait=.5)] +
                    [dict(mouse=[5, 3], buttons=4, wait=.05) for _ in range(12)] +
                    [dict(mouse=[0, 0], wait=.5)])
            assert_case(f'middle-{method.lower()}', before, [dict(mouse=[0, 0], wait=2)] + drag,
                        orbit_assertion)

        elif case in {'gizmos', 'touch'}:
            def gizmo_assertion(before, after, samples):
                if case == 'gizmos' and not any(any(m['left'] for m in s['platform']['mice'])
                                                for s in samples):
                    raise RuntimeError('OS did not receive the left press; invalid HID setup')
                assert abs(after['location'][0] - before['location'][0]) > .05, \
                    'gizmo drag did not move the object/bone'
                assert abs(after['location'][1]) < .01 and abs(after['location'][2]) < .01, \
                    'drag missed the gizmo X axis'
            if case == 'gizmos':
                events = [dict(mouse=[0, 0], wait=2), dict(mouse=[0, 0], buttons=1, wait=.5),
                          dict(mouse=[20, 0], buttons=1, wait=.4),
                          dict(mouse=[40, 0], buttons=1, wait=.3),
                          dict(mouse=[40, 0], buttons=1, wait=.3),
                          dict(mouse=[0, 0], wait=.4)]
            else:
                events = [dict(points=[[.5,.5]], phase=1),
                          dict(points=[[.5,.5]], phase=2, wait=.04),
                          dict(points=[[.5,.5]], phase=1, wait=.1),
                          dict(points=[[.54,.5]], phase=6, wait=.3),
                          dict(points=[[.57,.5]], phase=6, wait=.1),
                          dict(points=[[.57,.5]], phase=2, wait=.1)]
            assert_case(f'{case}-{kind}-gizmo', before, events, gizmo_assertion)

        elif case in {'pan', 'zoom'}:
            modifier = 0xe1 if case == 'pan' else 0xe0
            flag = 'shift' if case == 'pan' else 'ctrl'
            def navigation_assertion(before, after, samples):
                if not any(any(m['middle'] for m in s['platform']['mice']) for s in samples):
                    raise RuntimeError('OS did not receive the middle press; invalid HID setup')
                assert any(e['type'] == 'MIDDLEMOUSE' and e['value'] == 'PRESS' and e[flag]
                           for e in after['events']), f'{flag} was lost on middle-button navigation'
                if case == 'pan':
                    assert after['view_location'] != before['view_location'], 'Shift-middle did not pan'
                else:
                    assert abs(after['distance'] - before['distance']) > .01, 'Ctrl-middle did not zoom'
            events = [dict(mouse=[0, 0]), dict(key=modifier, phase=1, wait=.3),
                      dict(mouse=[0, 0], buttons=4, wait=.4)]
            events += [dict(mouse=[3, 3], buttons=4, wait=.05) for _ in range(20)]
            events += [dict(mouse=[0, 0], wait=.4), dict(key=modifier, phase=2, wait=.3)]
            assert_case(f'keyboard-{case}', before, events, navigation_assertion)

        elif case == 'keyboard':
            def key(usage):
                return [dict(key=usage, phase=1, wait=.08), dict(key=usage, phase=2, wait=.08)]
            def keyboard_assertion(before, after, samples):
                assert abs(after['location'][0] - 1) < .001, 'G, X, 1, Enter did not move the object'
                assert abs(after['object_rotation'][2] - 1.5707963) < .001, 'R, Z, 90 did not rotate'
                assert all(abs(v - 2) < .001 for v in after['object_scale']), 'S, 2 did not scale'
                assert any(s['state']['mode'] == 'EDIT' for s in samples), 'Tab did not enter Edit mode'
                assert after['mode'] == 'OBJECT', 'second Tab did not return to Object mode'
                assert any(e['type'] == 'RIGHTMOUSE' and e['value'] == 'PRESS' for e in after['events']), \
                    'right button did not reach Blender'
            events = key(0x0a) + key(0x1b) + key(0x1e) + key(0x28)
            events += key(0x15) + key(0x1d) + key(0x26) + key(0x27) + key(0x28)
            events += key(0x16) + key(0x1f) + key(0x28)
            events += key(0x0a) + key(0x1b) + key(0x26) + key(0x29)
            events += [dict(key=0x2b, phase=1, wait=.6), dict(key=0x2b, phase=2, wait=.08),
                       dict(key=0x2b, phase=1, wait=.6), dict(key=0x2b, phase=2, wait=.08)]
            events += [dict(mouse=[0, 0], wait=.5),
                       dict(mouse=[0, 0], buttons=2, wait=.4), dict(mouse=[0, 0], wait=.4)]
            events += key(0x29)
            assert_case('keyboard-move-and-mode', before, events, keyboard_assertion)
    finally:
        if recorder:
            recorder.send_signal(signal.SIGINT)
            recorder.wait(timeout=30)
            (output / 'demo.mp4').write_bytes(Path(recording.name + '/demo.mp4').read_bytes())
            recording.cleanup()
        for name in ('app-stdout.log', 'app-stderr.log'):
            path = folder / name
            if path.exists():
                (output / name).write_bytes(path.read_bytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--device', help='Use an existing booted test simulator')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--case', action='append', choices=(*CASES, 'wheel-sweep'))
    parser.add_argument('--fixture', choices=['cube', 'pose'])
    parser.add_argument('--orbit-method', choices=['TURNTABLE', 'TRACKBALL'])
    parser.add_argument('--wheel-delta', type=float, default=1,
                        help='Vertical wheel delta, including negative or fractional values')
    parser.add_argument('--wheel-reports', type=int, default=3,
                        help='Expected wheel reports; use 1 to isolate simulator delivery problems')
    parser.add_argument('--modifier-side', choices=['left', 'right'], default='left',
                        help='Keyboard side for modifier-wheel fixtures')
    parser.add_argument('--orientation', choices=['default', 'landscape'], default='default')
    parser.add_argument('--record', action='store_true', help='Record each ready fixture to demo.mp4')
    parser.add_argument('--skip-install', action='store_true', help='Use an already installed build')
    parser.add_argument('--restart-between-cases', action='store_true',
                        help='Reset SimulatorKit accessory services between fixtures')
    args = parser.parse_args()
    if args.wheel_reports < 1 or args.wheel_delta == 0:
        parser.error('wheel reports must be positive and wheel delta must be nonzero')
    owned = args.device is None
    device = args.device
    if owned:
        devices = json.loads(run('xcrun', 'simctl', 'list', 'devicetypes', '--json').stdout)
        kind = next(d['identifier'] for d in devices['devicetypes'] if 'iPad Pro 13' in d['name'])
        runtimes = json.loads(run('xcrun', 'simctl', 'list', 'runtimes', '--json').stdout)
        runtime = next(r['identifier'] for r in reversed(runtimes['runtimes'])
                       if r['isAvailable'] and r['name'].startswith('iOS'))
        device = run('xcrun', 'simctl', 'create', 'Blender input regression', kind, runtime).stdout.strip()
    try:
        if owned:
            run('xcrun', 'simctl', 'boot', device)
            run('xcrun', 'simctl', 'bootstatus', device, '-b')
        scenarios = []
        for case in args.case or CASES:
            if case == 'middle':
                scenarios += [(case, 'cube', method) for method in
                              ([args.orbit_method] if args.orbit_method else ('TURNTABLE', 'TRACKBALL'))]
            elif case in {'gizmos', 'touch'}:
                scenarios += [(case, kind, 'TURNTABLE') for kind in
                              ([args.fixture] if args.fixture else ('cube', 'pose'))]
            else:
                scenarios.append((case, 'cube', 'TURNTABLE'))
        for index, (case, kind, method) in enumerate(scenarios):
            if index > 0 and args.restart_between_cases:
                run('xcrun', 'simctl', 'shutdown', device)
                run('xcrun', 'simctl', 'boot', device)
                run('xcrun', 'simctl', 'bootstatus', device, '-b')
            name = f'{case}-{method.lower()}' if case == 'middle' else f'{case}-{kind}'
            exercise(args.app.resolve(), device, args.output.resolve() / name,
                     case, kind, method, args.skip_install or index > 0, args.record,
                     args.wheel_delta, args.wheel_reports, args.modifier_side, args.orientation)
    finally:
        if owned and device:
            run('xcrun', 'simctl', 'shutdown', device)
            run('xcrun', 'simctl', 'delete', device)


if __name__ == '__main__':
    main()
