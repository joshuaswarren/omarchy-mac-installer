import unittest

from Development.migration_staging.broker import Refused
from Development.migration_staging.capacity import MIB, plan_capacity


class CapacityTests(unittest.TestCase):
    def test_large_payload_gets_bounded_growth_not_whole_partition(self):
        plan = plan_capacity(4096 * MIB, 32768 * MIB, 8192 * MIB, 256 * MIB)
        self.assertEqual(plan.staging_filesystem_bytes, (4096 + 8192 + 256 + 32) * MIB)
        self.assertLess(plan.staging_filesystem_bytes, plan.partition_bytes - 32 * MIB)

    def test_exact_capacity_includes_shrink_work_and_unused_tail(self):
        self.assertEqual(plan_capacity(1024 * MIB, 1154 * MIB, 64 * MIB + 1, MIB).staging_filesystem_bytes,
                         1122 * MIB)
        with self.assertRaises(Refused):
            plan_capacity(1024 * MIB, 1154 * MIB, 64 * MIB + 1, 2 * MIB)

    def test_rounds_up_without_using_sparse_or_compression_savings(self):
        plan = plan_capacity(1024 * MIB, 2048 * MIB, 1, MIB)
        self.assertEqual(plan.staging_filesystem_bytes, 1058 * MIB)

    def test_insufficient_target_and_integer_overflow_fail_closed(self):
        for values in ((1024 * MIB, 1024 * MIB, MIB, MIB),
                       (2**62, 2**63 - 512, 2**62, MIB),
                       (1024 * MIB, 2048 * MIB, True, MIB),
                       (1024 * MIB + 1, 2048 * MIB, MIB, MIB)):
            with self.subTest(values=values), self.assertRaises(Refused):
                plan_capacity(*values)


if __name__ == "__main__":
    unittest.main()
