import os

# The suite asserts the Chinese text: pinned, whatever the machine's LANG (i18n.env_lang). The English side: test_i18n.py.
os.environ["BIRDCM_LANG"] = "zh"
