"""Regression cases for protocol scoping and legacy packet operations."""
from pathlib import Path
import importlib.util
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('classic_import', Path(__file__).with_name('import-flowseal.py'))
classic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classic)


def section(text, name):
    return re.search(r'^\[' + name + r'\]\n(.*?)(?=^\[|\Z)', text, re.M | re.S)[1]


class ClassicTranslationTests(unittest.TestCase):
    def test_imported_payloads_and_packet_cutoffs(self):
        general = (ROOT / 'presets/general.txt.in').read_text()
        self.assertIn('pos=1:seqovl=568:seqovl_pattern=classic_tls_clienthello_4pda_to', section(general, 'TCP_TLS'))
        self.assertEqual(section(general, 'GAME_TCP_RANGE').strip(), '<n3')
        self.assertEqual(section(general, 'GAME_UDP_RANGE').strip(), '<n2')
        alt4 = (ROOT / 'presets/ALT4.txt.in').read_text()
        self.assertIn('tcp_seq=1000:tcp_ack=-66000', section(alt4, 'TCP_TLS'))
        alt9 = (ROOT / 'presets/ALT9.txt.in').read_text()
        self.assertIn('host=ozon.ru:tcp_ts=-600000:tcp_md5', section(alt9, 'TCP_TLS'))

    def test_syndata_is_sent_once_for_each_syn(self):
        alt5 = (ROOT / 'presets/ALT5.txt.in').read_text()
        self.assertEqual(section(alt5, 'GAME_TCP_ACTIONS').count('--lua-desync=syndata'), 1)
        self.assertEqual(section(alt5, 'CLASSIC_TCP_PROFILE').count('--lua-desync=syndata'), 1)
        self.assertIn('--filter-l3=ipv4', section(alt5, 'CLASSIC_TCP_PROFILE'))

    def test_unknown_fakes_do_not_override_protocol_selection(self):
        exp = (ROOT / 'presets/EXP.txt.in').read_text()
        voice = section(exp, 'VOICE_COMPATIBLE')
        self.assertNotIn('payload=all', voice)
        self.assertIn('payload=unknown', voice)
        self.assertIn(':payload=all', section(exp, 'GAME_UDP_ACTIONS'))
        tcp = section(exp, 'GAME_TCP_ACTIONS')
        self.assertNotIn(':payload=all', tcp)
        self.assertIn(':payload=unknown', tcp)

    def test_real_clienthello_clone_and_no_duplicate_global_blobs(self):
        text = (ROOT / 'presets/FAKE TLS AUTO.txt.in').read_text()
        self.assertIn('tls_client_hello_clone:blob=classic_clone', text)
        self.assertIn('fake:blob=classic_clone', text)
        for path in (ROOT / 'presets').glob('*.txt.in'):
            if '[PRESET_INIT]' not in path.read_text(): continue
            init = section(path.read_text(), 'PRESET_INIT')
            self.assertNotRegex(init, r'--blob=(tls_google|tls_max|quic_google|stun):')


if __name__ == '__main__':
    unittest.main()
