#!/usr/bin/env bash
# OBSOLETE as of 2026-09-04. Do not use.
#
# This used to copy weights from the EBS backup onto the instance store after a
# stop/start. Model weights no longer live on the instance store at all: the
# model-pvc PV points straight at /home/ubuntu/llm-stack/hf-backup on the EBS
# root, so there is nothing to restore. Running this would recreate exactly the
# fragile layout that was removed. See CLUSTER.md gotcha 1.
#
# For what a stop/start does still need, run:
#   model-deployment/bin/post-restart.sh
echo "restore-models.sh is obsolete - weights are on EBS now. Run model-deployment/bin/post-restart.sh instead." >&2
exit 1
