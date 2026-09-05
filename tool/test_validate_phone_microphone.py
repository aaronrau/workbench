import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import validate_phone_microphone as mic


def node(label, enabled=True):
    return ET.Element('node', {'content-desc': label,
        'enabled': str(enabled).lower(), 'bounds': '[0,0][48,48]'})


class PhoneMicrophonePreflightTest(unittest.TestCase):
    def test_disconnects_glasses_before_requesting_microphone(self):
        states = [[node('Disconnect'), node('Start microphone', False)],
                  [node('Connect devices'), node('Start microphone')],
                  [node('Connect devices', False), node('Stop microphone')]]
        tapped = []
        with patch.object(mic, 'foreground'), patch.object(mic, 'ui_nodes', side_effect=states), \
             patch.object(mic, 'tap', side_effect=lambda adb, n: tapped.append(n.get('content-desc'))), \
             patch.object(mic.time, 'sleep'):
            report = mic.microphone_preflight(['adb', '-s', '<android-serial>'])
        self.assertTrue(report['ready'])
        self.assertEqual(tapped, ['Disconnect', 'Start microphone'])

    def test_disabled_microphone_cannot_satisfy_preflight(self):
        with patch.object(mic, 'foreground'), \
             patch.object(mic, 'ui_nodes', return_value=[node('Start microphone', False)]), \
             patch.object(mic, 'tap') as tap, \
             patch.object(mic.time, 'sleep'), \
             patch.object(mic.time, 'monotonic', side_effect=[0, 1, 100]):
            with self.assertRaisesRegex(RuntimeError, 'no speaker playback started'):
                mic.microphone_preflight(['adb', '-s', '<android-serial>'])
        tap.assert_not_called()

    def test_retries_missing_ui_and_accepts_xml_without_declaration(self):
        xml = '<hierarchy><node content-desc="Start microphone" enabled="true" /></hierarchy>'
        with patch.object(mic.subprocess, 'run'), \
             patch.object(mic.subprocess, 'check_output', side_effect=['', xml]), \
             patch.object(mic.time, 'sleep'):
            nodes = mic.ui_nodes(['adb', '-s', '<android-serial>'])
        self.assertIsNotNone(mic.find_control(nodes, 'Start microphone'))

    def test_unavailable_ui_fails_after_bounded_retries(self):
        with patch.object(mic.subprocess, 'run'), \
             patch.object(mic.subprocess, 'check_output', return_value='') as read, \
             patch.object(mic.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'hierarchy unavailable'):
                mic.ui_nodes(['adb', '-s', '<android-serial>'])
        self.assertEqual(read.call_count, 3)


if __name__ == '__main__':
    unittest.main()
