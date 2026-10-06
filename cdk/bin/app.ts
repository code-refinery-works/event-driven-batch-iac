#!/usr/bin/env node
import "source-map-support/register";
import * as cdk from "aws-cdk-lib";
import { EventDrivenBatchStack } from "../lib/stack";

const app = new cdk.App();

new EventDrivenBatchStack(app, "EventDrivenBatchStack", {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION ?? "ap-northeast-1",
  },
  tags: {
    Project: "EventDrivenBatch",
    ManagedBy: "AWS-CDK",
    Environment: app.node.tryGetContext("environment") ?? "dev",
  },
});