#!/usr/local/bin/julia

import Base: read, show, getindex

typealias Word UInt64
wordsize = 8

type Segment
    data::Array{Word,1}
end

type Message
    id::UInt64
    segments::Array{Ref{Segment},1}
end

function Message(s::IO)
    nsegments = Int64(read(s,UInt32) + 1)
    npadding = (nsegments + 1) % 2
    lengths = zeros(UInt32,nsegments)
    lengths = map(1:nsegments) do i
        read(s,UInt32)
    end
    readbytes(s,4*npadding)
    segments = map(lengths) do length
        Ref(Segment(read(s,UInt64,length)))
    end
    Message(0,segments)
end
getindex(m::Message,i) = getindex(m.segments,i)

getroot(s::Segment) = StructPointer(Ref(s),1)

pointer_type(v::Word)         = (0x0000000000000003 & v)
struct_data_offset(v::Word)   = (0x00000000FFFFFFFC & v) >> 2
struct_data_size(v::Word)     = (0x0000FFFF00000000 & v) >> 32
struct_pointer_count(v::Word) = (0xFFFF000000000000 & v) >> 48

type ObjectSize
    data_size::UInt16
    pointer_count::UInt16
end

abstract ObjectPointer
function ObjectPointer(m::Ref{Segment},i::Integer)
    v = m.x.data[i]
    t = pointer_type(v)
    if t == 0
        StructPointer(m,i)
    elseif t == 1
        ListPointer(m,i)
    elseif t == 2
        FarPointer(m,i)
    elseif t == 3
        CapabilityPointer(m,i)
    end
end

value{P<:ObjectPointer}(p::P) = p.segment.x.data[p.offset]

type StructPointer <: ObjectPointer
    segment::Ref{Segment}
    offset::Int64
    size::ObjectSize
end

function StructPointer(m::Ref{Segment},i::Integer)
    v = m.x.data[i]
    @assert pointer_type(v) == 0
    s = ObjectSize(struct_data_size(v),struct_pointer_count(v))
    StructPointer(Ref(m),i,s)
end

function show(io::IO,p::StructPointer)
    print(io,"StructPointer(")
    print(io,"addr=",p.offset)
    print(io,",data_offset=",data_offset(p))
    print(io,",data_size=",p.size.data_size)
    print(io,",pointer_count=",p.size.pointer_count,")")
end
data_offset(p::StructPointer) = struct_data_offset(value(p))

type TagPointer <: ObjectPointer
    segment::Ref{Segment}
    offset::Int64
    size::ObjectSize
end

function TagPointer(m::Ref{Segment},i::Integer)
    v = m.x.data[i]
    @assert pointer_type(v) == 0
    s = ObjectSize(struct_data_size(v),struct_pointer_count(v))
    TagPointer(Ref(m),i,s)
end

function show(io::IO,p::TagPointer)
    print(io,"TagPointer(")
    print(io,"addr=",p.offset)
    print(io,",element_count=",element_count(p))
    print(io,",data_size=",p.size.data_size)
    print(io,",pointer_count=",p.size.pointer_count,")")
end
element_count(p::TagPointer) = struct_data_offset(value(p))

type ListPointer <: ObjectPointer
    segment::Ref{Segment}
    offset::Int64
end
function ListPointer(m::Ref{Segment},i::Integer)
    v = m.x.data[i]
    @assert pointer_type(v) == 1
    ListPointer(Ref(m),i)
end

function show(io::IO,p::ListPointer)
    v = value(p)
    s = element_type(p)
    if s == 7
        offset = p.offset + 1 + Int64(struct_data_offset(v))
        tag = TagPointer(p.segment,offset)
        count = element_count(tag)
    else
        count = element_count(p)
    end
    print(io,"ListPointer(")
    print(io,"addr=",p.offset)
    print(io,",data_offset=",data_offset(p))
    print(io,",element_type=",s)
    print(io,",element_count=",count)
    if s == 7
        print(io,",list_size=",list_element_count(v))
    end
    print(io,")")
end

list_data_offset(v::Word)   = (0x00000000FFFFFFFC & v) >> 2
list_element_type(v::Word)  = (0x0000000700000000 & v) >> 32
list_element_count(v::Word) = (0xFFFFFFF800000000 & v) >> 35
element_count(p::ListPointer) = struct_data_offset(value(gettagobject(p)))
element_type(p::ListPointer) = list_element_type(value(p))
list_size(p::ListPointer) = list_element_count(value(p))
data_offset(p::ListPointer) = list_data_offset(value(p))

function getdata(p::StructPointer)
    @assert p.size.data_size > 0
    v = value(p)
    offset = p.offset + 1 + Int64(struct_data_offset(v))
    s = ObjectSize(struct_data_size(v),struct_pointer_count(v))
    ObjectPointer(p.segment,offset)
end

function getpointer(p::StructPointer,i::Int64)
    @assert i <= p.size.pointer_count
    v = value(p)
    offset = p.offset + 1 + Int64(struct_data_offset(v)) + Int64(struct_data_size(v)) + (i - 1)
    ObjectPointer(p.segment,offset)
end

function getobject(p::StructPointer,i::Int64)
    @assert i <= p.size.element_count
    v = value(p)
    offset = p.offset + 1 + Int64(struct_data_offset(v)) + Int64(struct_data_size(v)) + (i - 1)
    ObjectPointer(p.segment,offset)
end

function gettagobject(p::ListPointer)
    v = value(p)
    s = element_type(p)
    @assert s == 7
    offset = p.offset + 1 + Int64(struct_data_offset(v))
    TagPointer(p.segment,offset)
end

function getindex(p::ListPointer,i::Int64)
    v = value(p)
    n = element_count(p)
    @assert i > 0
    @assert i <= n
    s = element_type(p)
    offset = p.offset + 1 + Int64(struct_data_offset(v))
    if s == 0
        element_size = 0
        exit(1)
    elseif s == 1
        element_size = 1
        exit(2)
    elseif s == 2
        element_size = 1*8
        exit(3)
    elseif s == 3
        element_size = 2*8
        exit(4)
    elseif s == 4
        element_size = 4*8
        exit(5)
    elseif s == 5
        element_size = 8*8
        exit(6)
    elseif s == 6
        offset += (i-1)*8
        ObjectPointer(p.segment,offset)
    elseif s == 7
        tag = gettagobject(p)
        element_size = tag.size.data_size + tag.size.pointer_count
        offset += 1 + (i-1)*element_size
        exit(7)
        StructPointer
        # StructPointer(p.segment,offset)
    end
end

m = Message(STDIN)
@show s = m[1].x
@show req = getroot(s)
@show nodes = getpointer(req,1)
@show gettagobject(nodes)
@show requested_files = getpointer(req,2)
@show gettagobject(requested_files)
@show requested_files[1]
