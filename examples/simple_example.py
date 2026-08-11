#!/usr/bin/env python3
"""Simple example script to demonstrate EasyCalendar parsing."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from src.parser.rule_parser import RuleParser


def main():
    """Run example usage."""
    print("=" * 60)
    print("EasyCalendar 示例使用")
    print("=" * 60)

    parser = RuleParser()

    example_texts = [
        "明天上午9点在A栋会议室开会讨论项目进度",
        "2024年3月20日下午2点有一个重要约会",
        "下周三上午10点参加培训课程，持续2小时",
        "周五下午3点提醒我给客户打电话",
    ]

    print("\n文字日程解析示例：\n")
    for text in example_texts:
        print(f"原文: {text}")
        result = parser.parse(text)

        for candidate in result.candidates:
            print(f"  类型: {candidate.type.value}")
            print(f"  标题: {candidate.title}")
            print(f"  开始时间: {candidate.start_at or '未指定'}")
            print(f"  截止时间: {candidate.due_at or '未指定'}")
            print(f"  地点: {candidate.location or '未指定'}")
            print(f"  置信度: {candidate.confidence:.2f}")
            print()

    print("\n" + "=" * 60)
    print("示例运行完成！")
    print("=" * 60)


if __name__ == "__main__":
    main()
