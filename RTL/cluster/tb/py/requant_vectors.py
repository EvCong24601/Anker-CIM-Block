"""Exact integer Requant vectors; no floating point or DUT helper reuse."""
import random
from pathlib import Path


def golden(psum, multiplier, shift, zp):
    product = psum * multiplier
    if shift >= 0:
        rounded = product * (2 ** shift)
    else:
        quotient, remainder = divmod(abs(product), 2 ** (-shift))
        quotient += 2 * remainder >= 2 ** (-shift)
        rounded = -quotient if product < 0 else quotient
    return min(127, max(-128, rounded + zp))


def write_vectors(path):
    cases = []
    # Sign extremes, exact products, positive/negative scale and shift bounds.
    values = [-(2**31), -(2**31)+1, -129, -128, -127, -3, -1,
              0, 1, 3, 126, 127, 128, 2**31-1]
    for p in values:
        for m in [-(2**31), -3, -1, 0, 1, 7, 2**31-1]:
            for s in [-31, -23, -7, -1, 0, 1, 7, 31]:
                for z in [-(2**31), -128, -1, 0, 1, 127, 2**31-1]:
                    cases.append((p, m, s, z, 'signed-extreme-and-scale'))
    # Half ties and adjacent values must round symmetrically away from zero.
    for k in [1, 2, 7, 16, 31]:
        for sign in [-1, 1]:
            for delta in [-1, 0, 1]:
                for z in [-127, 0, 1, 126]:
                    p = sign * (2**(k-1)+delta)
                    cases.append((p, 1, -k, z, 'half-tie-and-neighbors'))
    # In particular, left-shifted values must not clip before adding zp.
    cases.extend([(1, 1, 31, -(2**31), 'zp-cancels-left-shift'),
                  (-1, 1, 31, 2**31-1, 'zp-cancels-negative-shift'),
                  (-1, 1, -1, 1, 'zp-after-negative-half-round')])
    rng = random.Random(0x524551)
    for _ in range(3000):
        cases.append((rng.randrange(-(2**31), 2**31),
                      rng.randrange(-(2**31), 2**31), rng.randrange(-31, 32),
                      rng.randrange(-(2**31), 2**31), 'seeded-random'))
    # Non-saturated results: random extremes above mostly exercise clipping.
    for _ in range(1000):
        cases.append((rng.randrange(-4096, 4096), rng.randrange(-32, 33),
                      rng.randrange(-16, 1), rng.randrange(-100, 101), 'small-result-random'))
    path = Path(path)
    path.write_text(''.join(f'{p} {m} {s} {z} {golden(p,m,s,z)} {name}\n'
                            for p,m,s,z,name in cases), encoding='ascii')
    return len(cases)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    print(f'PASS generated Requant vectors: {write_vectors(args.output)}')
