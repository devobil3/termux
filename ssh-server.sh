#!/data/data/com.termux/files/usr/bin/bash
pkg install openssh -y
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCSZW/klhafv8Et76LRgx9ewSPw0E+cfD3Vl8n09zvhtr5tp+tTBCNj3DMp6PpOVLvE87lt6AAGApZ0obb/OoL0pFv3Uj1Fi6ZV0wlaKiqeDYnaqLZgo69QPDIIqs7ZMtYgcxbuLnAnENf1dYM/A++KvfzUpCXv7ZPvNWOCik+HyhlC2Fcj5llmyelgJ8t0z5BjGEgc+qMITHuZiXgUrcbKaicZUyuXh2SawGwdr8Lik0lt+dsQuVaUzhFdJyMlGEFCcJSWu7tIy/kw34VYeZr3k1ZoCuyfS+9pKBUa3iSQDsGtoaVdFPuppI4fLAH2YoCaCfIwSdCgVCtf2dbg9sICcv/+5PO0xPPKV3TQ/T3F2kBk4h5T/2uyjOL+Q4lfs0g4MqmuXKPMDT5zwfxLPKvBX102mQWnU1GqylceSc4yyhVc9MbM9HqB++wpuoKuafSM+oqUUBdBj3oDEvpbKUiLARKF+AI4t36D5zSzBQ0CqMybecy0uT1sx3GjbI7tRDc= u0_a349@localhost" > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
sshd
