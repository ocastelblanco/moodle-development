# SSM Automation aws:executeScript handler (Python 3.11).
# Publishes a message to the scaling alerts SNS topic.
import boto3


def handler(events, context):
    topic_arn = events.get("TopicArn", "")
    subject = str(events.get("Subject", "Moodle scaling notification"))[:100]
    message = str(events.get("Message", ""))
    if topic_arn:
        boto3.client("sns").publish(TopicArn=topic_arn, Subject=subject, Message=message)
    return {"Published": bool(topic_arn)}
