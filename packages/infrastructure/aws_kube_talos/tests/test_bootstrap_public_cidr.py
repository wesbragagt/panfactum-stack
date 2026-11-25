import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from bootstrap_public_cidr import operator_cidr


class BootstrapPublicCIDRTest(unittest.TestCase):
    @patch("bootstrap_public_cidr.urllib.request.build_opener")
    def test_detects_runner_ipv4(self, build_opener):
        opener = build_opener.return_value
        opener.open.return_value.__enter__.return_value.read.return_value = b"8.8.8.8\n"

        self.assertEqual(operator_cidr(), "8.8.8.8/32")
        opener.open.assert_called_once_with("https://checkip.amazonaws.com", timeout=5)
        self.assertEqual(build_opener.call_args.args[0].proxies, {})

    @patch("bootstrap_public_cidr.urllib.request.build_opener")
    def test_rejects_invalid_or_non_public_address(self, build_opener):
        response = build_opener.return_value.open.return_value.__enter__.return_value
        for address in (b"0.0.0.0", b"10.1.2.3", b"224.0.0.1", b"8.8.8.8/0", b"2600::1", b""):
            with self.subTest(address=address):
                response.read.return_value = address
                with self.assertRaises(ValueError):
                    operator_cidr()
