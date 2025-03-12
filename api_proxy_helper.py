import chromadb
import json
import requests
import sys
import os

def get_models_from_ollama(base_url, include_details=False):
    """Get available models from Ollama API"""
    url = f"{base_url}/api/tags"
    
    try:
        response = requests.get(url)
        response.raise_for_status()
        result = response.json()
        
        if 'models' in result:
            models = result['models']
            
            # If include_details is False, just return model names
            if not include_details:
                model_names = [model['name'] for model in models]
                return {
                    "models": model_names,
                    "count": len(model_names)
                }
            else:
                return {
                    "models": models,
                    "count": len(models)
                }
        else:
            print(f"Error: Unexpected response format - {result}", file=sys.stderr)
            return {"error": "Unexpected response format"}
    except Exception as e:
        print(f"Error getting models: {str(e)}", file=sys.stderr)
        return {"error": f"Error getting models: {str(e)}"}
        
def get_embedding_from_ollama(text, model, base_url):
    """Get embeddings from Ollama API"""
    url = f"{base_url}/api/embeddings"
    
    data = {
        "model": model,
        "prompt": text
    }
    
    try:
        response = requests.post(url, json=data)
        response.raise_for_status()
        result = response.json()
        
        if 'embedding' in result:
            return result['embedding']
        else:
            print(f"Error: Unexpected response format - {result}", file=sys.stderr)
            return None
    except Exception as e:
        print(f"Error getting embedding: {str(e)}", file=sys.stderr)
        return None

def query_chroma(query_text, db_path, embedding_model, base_url, n_results=5, threshold=0.75):
    """Query ChromaDB for relevant documents"""
    try:
        # Get embedding for query
        query_embedding = get_embedding_from_ollama(query_text, embedding_model, base_url)
        if not query_embedding:
            return {"error": "Failed to get embedding for query"}
        
        # Connect to ChromaDB
        client = chromadb.PersistentClient(path=db_path, settings=Settings(anonymized_telemetry=False))
        
        # Get collection
        try:
            collection = client.get_collection(name="document_collection")
        except Exception as e:
            return {"error": f"Collection not found: {str(e)}"}
        
        # Query the collection
        results = collection.query(
            query_embeddings=[query_embedding],
            n_results=n_results,
            include=["documents", "metadatas", "distances"]
        )
        
        # Process and filter results
        processed_results = []
        
        if results["distances"] and results["distances"][0]:
            # Convert distances to similarity scores (1 - distance)
            similarities = [1 - dist for dist in results["distances"][0]]
            
            for i, (doc, metadata, similarity) in enumerate(zip(results["documents"][0], results["metadatas"][0], similarities)):
                # Only include results above the threshold
                if similarity >= threshold:
                    processed_results.append({
                        "document": doc,
                        "metadata": metadata,
                        "similarity": similarity
                    })
        
        return {
            "results": processed_results,
            "count": len(processed_results)
        }
    except Exception as e:
        return {"error": f"Error querying ChromaDB: {str(e)}"}

def send_chat_to_ollama(messages, model, context, base_url):
    """Send chat completion request to Ollama API"""
    try:
        url = f"{base_url}/api/chat"
        
        # Prepare the request with context
        data = {
            "model": model,
            "messages": messages,
            "options": {
                "temperature": 0.7,
                "num_ctx": 16384  # Ensure context can fit
            }
        }
        
        # Add context if provided
        if context:
            data["context"] = context
        
        response = requests.post(url, json=data, stream=False)
        response.raise_for_status()
        return response.json()
    except Exception as e:
        return {"error": f"Error sending chat to Ollama: {str(e)}"}

# Command handler
if __name__ == "__main__":
    command = sys.argv[1]
    
    if command == "query":
        query_text = sys.argv[2]
        db_path = sys.argv[3]
        embedding_model = sys.argv[4]
        base_url = sys.argv[5]
        n_results = int(sys.argv[6])
        threshold = float(sys.argv[7])
        
        result = query_chroma(query_text, db_path, embedding_model, base_url, n_results, threshold)
        print(json.dumps(result))
    
    elif command == "chat":
        messages_json = sys.argv[2]
        model = sys.argv[3]
        context_json = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] != "null" else None
        base_url = sys.argv[5]
        
        messages = json.loads(messages_json)
        context = json.loads(context_json) if context_json else None
        
        result = send_chat_to_ollama(messages, model, context, base_url)
        print(json.dumps(result))
    
    elif command == "models":
        base_url = sys.argv[2]
        include_details = sys.argv[3].lower() == "true" if len(sys.argv) > 3 else False
        
        result = get_models_from_ollama(base_url, include_details)
        print(json.dumps(result))
