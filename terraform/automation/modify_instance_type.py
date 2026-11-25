# SSM Automation aws:executeScript handler (Python 3.11).
# Changes the instance type of a stopped EC2 instance.
import boto3


def handler(events, context):
    ec2 = boto3.client("ec2")
    ec2.modify_instance_attribute(InstanceId=events["InstanceId"], InstanceType={"Value": events["InstanceType"]})
    return {"InstanceType": events["InstanceType"]}
