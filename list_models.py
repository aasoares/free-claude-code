import google.generativeai as genai
import os
from dotenv import load_dotenv
load_dotenv()

api_key = os.getenv("GOOGLE_API_KEY")
genai.configure(api_key=api_key, transport="rest")

models = genai.list_models()
for m in models:
    print(f"Name: {m.name}")
    print(f"  Display: {m.display_name}")
    print(f"  Supported: {m.supported_generation_methods}")
    print()
