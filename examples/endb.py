#!/usr/bin/env python3

import base64
from datetime import date, datetime, time
import json
import requests

def from_json_ld(obj):
    match obj.get('@type', None):
        case 'xsd:dateTime':
            return datetime.fromisoformat(obj['@value'].replace('Z', '+00:00'))
        case 'xsd:date':
            return date.fromisoformat(obj['@value'])
        case 'xsd:time':
            return time.fromisoformat(obj['@value'])
        case 'xsd:base64Binary':
            return base64.b64decode(obj['@value'])
        case _:
            return obj.get('@graph', obj)

class JSONLDEncoder(json.JSONEncoder):
    def default(self, obj):
        match obj:
           case datetime():
               return {'@value': datetime.isoformat(obj), '@type': 'xsd:dateTime'}
           case date():
               return {'@value': date.isoformat(obj), '@type': 'xsd:date'}
           case time():
               return {'@value': time.isoformat(obj), '@type': 'xsd:time'}
           case bytes():
               return {'@value': base64.b64encode(obj).decode(), '@type': 'xsd:base64Binary'}
           case _:
               return super().default(obj)

def sql(q, parameters=[], headers={'Accept': 'application/ld+json'}, auth=None, url='http://localhost:3803/sql'):
    payload = {'q': q, 'parameter': [json.dumps(x, cls=JSONLDEncoder) for x in parameters]}
    r = requests.post(url, payload, headers=headers, auth=auth)
    r.raise_for_status()
    return r.json(object_hook=from_json_ld)

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        print(sql(sys.argv[1]))