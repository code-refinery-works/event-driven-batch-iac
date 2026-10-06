import * as cdk from "aws-cdk-lib";
import { Construct } from "constructs";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import * as sqs from "aws-cdk-lib/aws-sqs";
import * as ecs from "aws-cdk-lib/aws-ecs";
import * as iam from "aws-cdk-lib/aws-iam";
import * as logs from "aws-cdk-lib/aws-logs";
import * as events from "aws-cdk-lib/aws-events";
import * as targets from "aws-cdk-lib/aws-events-targets";
import * as cw from "aws-cdk-lib/aws-cloudwatch";

export class EventDrivenBatchStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    const env   = this.node.tryGetContext("environment") ?? "dev";
    const image = this.node.tryGetContext("containerImage") ?? "public.ecr.aws/amazonlinux/amazonlinux:latest";
    const prefix = `edb-${env}`;

    // ── VPC ──────────────────────────────────────────────────────────────────
    const vpc = new ec2.Vpc(this, "Vpc", {
      maxAzs: 2,
      natGateways: 0,
      subnetConfiguration: [{ name: "Private", subnetType: ec2.SubnetType.PRIVATE_ISOLATED, cidrMask: 24 }],
    });

    const ecssg = new ec2.SecurityGroup(this, "EcsSg", { vpc, allowAllOutbound: false });
    ecssg.addEgressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443), "HTTPS egress for AWS APIs");

    // ── SQS ──────────────────────────────────────────────────────────────────
    const dlq = new sqs.Queue(this, "Dlq", {
      queueName:              `${prefix}-dlq`,
      retentionPeriod:        cdk.Duration.days(14),
      encryption:             sqs.QueueEncryption.SQS_MANAGED,
    });

    const queue = new sqs.Queue(this, "Queue", {
      queueName:             `${prefix}-queue`,
      visibilityTimeout:     cdk.Duration.seconds(900),
      retentionPeriod:       cdk.Duration.days(4),
      encryption:            sqs.QueueEncryption.SQS_MANAGED,
      deadLetterQueue:       { queue: dlq, maxReceiveCount: 3 },
    });

    // ── EventBridge ──────────────────────────────────────────────────────────
    const rule = new events.Rule(this, "Rule", {
      ruleName:   `${prefix}-rule`,
      schedule:   events.Schedule.expression(this.node.tryGetContext("scheduleExpression") ?? "rate(1 hour)"),
    });
    rule.addTarget(new targets.SqsQueue(queue));

    // ── ECS ──────────────────────────────────────────────────────────────────
    const cluster = new ecs.Cluster(this, "Cluster", { vpc, clusterName: `${prefix}-cluster` });

    const logGroup = new logs.LogGroup(this, "LogGroup", {
      logGroupName:  `/ecs/${prefix}`,
      retention:     logs.RetentionDays.ONE_MONTH,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const taskDef = new ecs.FargateTaskDefinition(this, "TaskDef", {
      family: `${prefix}-task`,
      cpu:    256,
      memoryLimitMiB: 512,
    });

    taskDef.addContainer("batch", {
      image:   ecs.ContainerImage.fromRegistry(image),
      environment: { QUEUE_URL: queue.queueUrl },
      logging: ecs.LogDrivers.awsLogs({ streamPrefix: "batch", logGroup }),
    });

    // IAM: task role – SQS consume only
    queue.grantConsumeMessages(taskDef.taskRole);

    // ── CloudWatch Alarm (DLQ) ────────────────────────────────────────────────
    new cw.Alarm(this, "DlqAlarm", {
      alarmName:          `${prefix}-dlq-not-empty`,
      alarmDescription:   "DLQ has messages - batch processing failure detected",
      metric:             dlq.metricApproximateNumberOfMessagesVisible({ period: cdk.Duration.minutes(1) }),
      threshold:          1,
      evaluationPeriods:  1,
      comparisonOperator: cw.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      treatMissingData:   cw.TreatMissingData.NOT_BREACHING,
    });

    // ── Outputs ───────────────────────────────────────────────────────────────
    new cdk.CfnOutput(this, "QueueUrl",      { value: queue.queueUrl });
    new cdk.CfnOutput(this, "DlqUrl",        { value: dlq.queueUrl });
    new cdk.CfnOutput(this, "ClusterArn",    { value: cluster.clusterArn });
    new cdk.CfnOutput(this, "TaskDefArn",    { value: taskDef.taskDefinitionArn });
    new cdk.CfnOutput(this, "LogGroupName",  { value: logGroup.logGroupName });
  }
}