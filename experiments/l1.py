from torch import linalg as LA
import torch 

A = torch.arange(64, dtype=torch.float).reshape(4, 4, 4)
recieve = torch.diagonal(A, dim1=0, dim2=1, offset=0)
result = torch.linalg.norm(recieve,dim=1)

print(result)
