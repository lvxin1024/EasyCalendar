# text2calendar - Text to Calendar Event Parser

A Python library for parsing natural language text into calendar events, with support for multiple calendar providers.

## Features

- **Smart Text Parsing**: Extract calendar events from natural language text without AI/LLM
- **Multi-Calendar Support**: Google Calendar, Outlook, iCal compatibility
- **Rule-Based Engine**: Stable and predictable parsing using traditional NLP techniques
- **Extensible Design**: Easy to add new calendar providers and parsing rules

## Installation

```bash
pip install -r requirements.txt
```

## Usage

```python
from src.parser.rule_parser import RuleParser
from src.calendar_client.google_calendar import GoogleCalendarClient

# Parse text to events
parser = RuleParser()
text = "明天上午9点开会讨论项目进度"
events = parser.parse(text)

# Sync to Google Calendar
client = GoogleCalendarClient()
for event in events:
    client.create_event(event)
```

## Architecture

- `parser/`: Text parsing module for extracting calendar events
- `calendar_client/`: Calendar provider clients
- `api/`: REST API layer
- `utils/`: Utility functions

## License

MIT
