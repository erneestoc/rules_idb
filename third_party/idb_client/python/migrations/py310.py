import enum
import sys

if sys.version_info >= (3, 11):
    StrEnum310 = enum.StrEnum
else:
    class StrEnum310(str, enum.Enum):
        def __str__(self):
            return str(self.value)
