"""pytest config — make the python/ directory importable for the tests."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
