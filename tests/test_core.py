import unittest

from nftables_forwarder.core import ForwardRule, NftScriptBuilder, parse_port_mapping


class CoreTests(unittest.TestCase):
    def test_parse_tcp_mapping_with_default_family(self):
        rule = parse_port_mapping("8080:10.0.0.2:80")
        self.assertEqual(rule, ForwardRule(listen_port=8080, target_host="10.0.0.2", target_port=80, protocol="tcp"))

    def test_parse_udp_mapping(self):
        rule = parse_port_mapping("5353:10.0.0.3:53/udp")
        self.assertEqual(rule.protocol, "udp")
        self.assertEqual(rule.listen_port, 5353)
        self.assertEqual(rule.target_host, "10.0.0.3")
        self.assertEqual(rule.target_port, 53)

    def test_parse_rejects_invalid_protocol(self):
        with self.assertRaisesRegex(ValueError, "protocol"):
            parse_port_mapping("8080:10.0.0.2:80/icmp")

    def test_builder_generates_nat_and_forward_rules(self):
        builder = NftScriptBuilder(table="portfw", interface="eth0")
        script = builder.build_apply_script([
            ForwardRule(8080, "10.0.0.2", 80, "tcp"),
            ForwardRule(5353, "10.0.0.3", 53, "udp"),
        ])

        self.assertIn("table inet portfw", script)
        self.assertIn("type nat hook prerouting priority dstnat", script)
        self.assertIn('iifname "eth0" tcp dport 8080 dnat ip to 10.0.0.2:80', script)
        self.assertIn('iifname "eth0" udp dport 5353 dnat ip to 10.0.0.3:53', script)
        self.assertIn("ip daddr 10.0.0.2 tcp dport 80 accept", script)
        self.assertIn("ip daddr 10.0.0.3 udp dport 53 accept", script)

    def test_builder_generates_delete_script(self):
        builder = NftScriptBuilder(table="portfw")
        self.assertEqual(builder.build_delete_script().strip(), "delete table inet portfw")


if __name__ == "__main__":
    unittest.main()
