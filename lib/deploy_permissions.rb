# frozen_string_literal: true

# The IAM actions a deploy run needs, checked with the policy simulator.
module DeployPermissions
  LAMBDA = %w[lambda:PublishVersion cloudfront:ListDistributions cloudfront:GetDistributionConfig cloudfront:UpdateDistribution].freeze
  AMI = %w[ec2:DescribeInstances ec2:DescribeTags ec2:CreateImage ec2:DescribeImages ec2:DescribeSnapshots ssm:SendCommand ssm:GetCommandInvocation].freeze
  OTHER_DEPLOYS = %w[codedeploy:ListDeployments codedeploy:ListDeploymentInstances].freeze
  STACK = %w[cloudformation:ListStacks cloudformation:DescribeStacks cloudformation:GetTemplateSummary cloudformation:DescribeStackEvents cloudformation:UpdateStack ssm:GetParameters ssm:PutParameter].freeze
  ROLLOUT = %w[autoscaling:DescribeAutoScalingGroups autoscaling:UpdateAutoScalingGroup].freeze
  LOAD_BALANCER = %w[elasticloadbalancing:DescribeTargetGroups elasticloadbalancing:DescribeTargetHealth].freeze

  USER_ARN = %r{\Aarn:[^:]+:iam::\d+:user/}
  ASSUMED_ROLE_ARN = %r{\Aarn:(?<partition>[^:]+):sts::(?<account>\d+):assumed-role/(?<role>[^/]+)/}
  SIMULATION_BATCH_SIZE = 50
  private_constant :LAMBDA, :AMI, :OTHER_DEPLOYS, :STACK, :ROLLOUT, :LOAD_BALANCER, :USER_ARN, :ASSUMED_ROLE_ARN, :SIMULATION_BATCH_SIZE

  module_function

  def required(options, load_balanced:, building:)
    return { 'publishing the lambda': LAMBDA } if options[:lambda_publish_version]

    needs = {}
    needs[:'building the AMIs'] = AMI if building
    needs[:'looking for other deploys'] = OTHER_DEPLOYS unless options[:'skip-other-deploy-check']
    return needs if options[:create_ami_only] && building

    needs[:'updating the stack'] = STACK
    needs[:'rolling out the auto scaling groups'] = ROLLOUT
    needs[:'checking the load balancers'] = LOAD_BALANCER if load_balanced
    needs
  end

  def simulation_arn(iam, caller_arn)
    return caller_arn if caller_arn.match?(USER_ARN)

    role = caller_arn.match(ASSUMED_ROLE_ARN)
    return if role.nil?

    begin
      iam.get_role({ role_name: role[:role] }).role.arn
    rescue Aws::IAM::Errors::ServiceError
      "arn:#{role[:partition]}:iam::#{role[:account]}:role/#{role[:role]}"
    end
  end

  def denied(iam, arn, actions)
    actions.each_slice(SIMULATION_BATCH_SIZE).flat_map do |slice|
      results = iam.simulate_principal_policy({ policy_source_arn: arn, action_names: slice }).flat_map(&:evaluation_results)
      results.filter_map { |result| result.eval_action_name unless result.eval_decision == 'allowed' }
    end
  end
end
