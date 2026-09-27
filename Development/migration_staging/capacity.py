"""Conservative extent arithmetic for a disposable staging experiment."""

from dataclasses import asdict, dataclass

from .broker import MAX_OFFSET, Refused


MIB = 1024 * 1024
SHRINK_WORK = 32 * MIB
PARTITION_TAIL = 32 * MIB


@dataclass(frozen=True)
class CapacityPlan:
    original_filesystem_bytes: int
    partition_bytes: int
    ciphertext_bytes: int
    metadata_reserve_bytes: int
    staging_filesystem_bytes: int
    shrink_work_bytes: int = SHRINK_WORK
    unused_partition_tail_bytes: int = PARTITION_TAIL

    def document(self):
        return asdict(self)


def plan_capacity(original_filesystem_bytes, partition_bytes, ciphertext_bytes, metadata_reserve_bytes):
    inputs = (original_filesystem_bytes, partition_bytes, ciphertext_bytes, metadata_reserve_bytes)
    if any(type(value) is not int or not 0 < value <= MAX_OFFSET for value in inputs):
        raise Refused("capacity inputs must be positive bounded integer byte counts")
    if original_filesystem_bytes % MIB or partition_bytes % 512:
        raise Refused("filesystem/partition extent is not aligned")
    # Do not spend the image's original free allowance on migration. Added
    # capacity covers all ciphertext, explicit metadata headroom and shrink work.
    needed = original_filesystem_bytes + ciphertext_bytes + metadata_reserve_bytes + SHRINK_WORK
    staging = ((needed + MIB - 1) // MIB) * MIB
    if staging > MAX_OFFSET or staging > partition_bytes - PARTITION_TAIL:
        raise Refused("target cannot contain staging plus the required unused tail")
    return CapacityPlan(original_filesystem_bytes, partition_bytes, ciphertext_bytes,
                        metadata_reserve_bytes, staging)
