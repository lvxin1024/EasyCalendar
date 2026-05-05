#!/usr/bin/env python3
"""Simple example script to demonstrate text2calendar usage."""

from datetime import datetime
from src.parser.rule_parser import RuleParser
from src.calendar_client.ical_client import ICalClient


def main():
    """Run example usage."""
    print("=" * 60)
    print("text2calendar 示例使用")
    print("=" * 60)

    parser = RuleParser()

    example_texts = [
        "明天上午9点在A栋会议室开会讨论项目进度",
        "2024年3月20日下午2点有一个重要约会",
        "下周三上午10点参加培训课程，持续2小时",
        "周五下午3点提醒我给客户打电话",
    ]

    print("\n1. 文字日程解析示例：\n")
    for text in example_texts:
        print(f"原文: {text}")
        result = parser.parse(text)

        for event in result.events:
            print(f"  标题: {event.title}")
            print(f"  开始时间: {event.start_time}")
            print(f"  结束时间: {event.end_time}")
            print(f"  地点: {event.location or '未指定'}")
            print(f"  参与者: {', '.join(event.attendees) if event.attendees else '无'}")
            print()

    print("\n2. 日历同步示例 (iCal):\n")
    client = ICalClient()

    sample_events = [
        {
            "title": "团队周会",
            "start": datetime(2024, 3, 20, 9, 0),
            "end": datetime(2024, 3, 20, 10, 0),
        },
        {
            "title": "项目评审",
            "start": datetime(2024, 3, 21, 14, 0),
            "end": datetime(2024, 3, 21, 16, 0),
        },
    ]

    for event_data in sample_events:
        from src.parser.models import CalendarEvent
        event = CalendarEvent(
            title=event_data["title"],
            start_time=event_data["start"],
            end_time=event_data["end"],
        )
        event_id = client.create_event(event)
        print(f"创建事件: {event_data['title']} (ID: {event_id})")

    print("\n3. 导出日历：\n")
    filepath = client.export_calendar("example_calendar.ics")
    print(f"日历已导出到: {filepath}")

    print("\n" + "=" * 60)
    print("示例运行完成！")
    print("=" * 60)


if __name__ == "__main__":
    main()
