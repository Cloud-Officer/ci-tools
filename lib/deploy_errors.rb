# frozen_string_literal: true

# How a failed deploy ended, so the exit code tells callers whether production was put back.
module DeployErrors
  # The rollout failed and every group is back on its previous AMI.
  class RolledBack < StandardError; end

  # The rollout failed and its state is unknown or the rollback failed too.
  class NeedsHuman < StandardError; end
end
