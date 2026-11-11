// coherent_memory.c: Vulkan layer VK_LAYER_VMLAB_coherent_memory, for the render server of the
// Windows GPU VM on NVIDIA (win-venus.sh start nvidia).
//
// On this laptop (Intel CPU, NVIDIA GPU) the GPU and a guest CPU do not see each other's writes
// reliably in NVIDIA's uncached host-visible memory type: the guest's Direct3D 11 uploads reach
// the GPU with 64-byte holes (dark dashes in the wallpaper). The cached host-visible type of the
// same heap is coherent. vmlab-win3d's guest patches 0065 to 0067 move its Vulkan and OpenGL
// drivers to the cached type but not its Direct3D 9 to 11 driver (its docs/nvfb.md), so this
// layer does it from the host for every guest driver: an uncached host-visible type that has a
// cached counterpart is reported as not host-visible, and guests then choose the counterpart.
//
// Build: ./build.sh. Nothing else is intercepted; device creation only passes through.
#include <stdio.h>
#include <string.h>
#include <vulkan/vk_layer.h>
#include <vulkan/vulkan.h>

static PFN_vkGetInstanceProcAddr next_gipa;
static PFN_vkGetDeviceProcAddr next_gdpa;
static PFN_vkCreateDevice next_create_device;
static PFN_vkGetPhysicalDeviceMemoryProperties next_props;
static PFN_vkGetPhysicalDeviceMemoryProperties2 next_props2;

static void hide_uncached(VkPhysicalDeviceMemoryProperties *p) {
    const VkMemoryPropertyFlags visible = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    static int said;
    for (uint32_t i = 0; i < p->memoryTypeCount; i++) {
        VkMemoryPropertyFlags f = p->memoryTypes[i].propertyFlags;
        if ((f & visible) != visible || (f & (VK_MEMORY_PROPERTY_HOST_CACHED_BIT | VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)))
            continue;
        // the counterpart: the same heap, every flag of this type, and cached
        VkMemoryPropertyFlags want = f | VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
        for (uint32_t j = 0; j < p->memoryTypeCount; j++) {
            if (p->memoryTypes[j].heapIndex != p->memoryTypes[i].heapIndex || (p->memoryTypes[j].propertyFlags & want) != want)
                continue;
            p->memoryTypes[i].propertyFlags = f & ~visible;
            if (!said++)
                fprintf(stderr, "vmlab coherent_memory: memory type %u (uncached) is hidden, guests use type %u (cached)\n", i, j);
            break;
        }
    }
}

static VKAPI_ATTR void VKAPI_CALL props(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties *p) {
    next_props(pd, p);
    hide_uncached(p);
}

static VKAPI_ATTR void VKAPI_CALL props2(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties2 *p) {
    if (next_props2)
        next_props2(pd, p);
    else
        next_props(pd, &p->memoryProperties);
    hide_uncached(&p->memoryProperties);
}

static VKAPI_ATTR VkResult VKAPI_CALL create_instance(const VkInstanceCreateInfo *info, const VkAllocationCallbacks *alloc,
                                                      VkInstance *instance) {
    VkLayerInstanceCreateInfo *link = (VkLayerInstanceCreateInfo *)info->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_INSTANCE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO))
        link = (VkLayerInstanceCreateInfo *)link->pNext;
    if (!link || !link->u.pLayerInfo)
        return VK_ERROR_INITIALIZATION_FAILED;
    PFN_vkGetInstanceProcAddr gipa = link->u.pLayerInfo->pfnNextGetInstanceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    PFN_vkCreateInstance create = (PFN_vkCreateInstance)gipa(VK_NULL_HANDLE, "vkCreateInstance");
    if (!create)
        return VK_ERROR_INITIALIZATION_FAILED;
    VkResult r = create(info, alloc, instance);
    if (r != VK_SUCCESS)
        return r;
    // The chain below this layer is the same for every instance of the process, so one set of
    // pointers serves them all.
    next_gipa = gipa;
    next_create_device = (PFN_vkCreateDevice)gipa(*instance, "vkCreateDevice");
    next_props = (PFN_vkGetPhysicalDeviceMemoryProperties)gipa(*instance, "vkGetPhysicalDeviceMemoryProperties");
    PFN_vkVoidFunction p2 = gipa(*instance, "vkGetPhysicalDeviceMemoryProperties2");
    if (!p2)
        p2 = gipa(*instance, "vkGetPhysicalDeviceMemoryProperties2KHR");
    if (p2)
        next_props2 = (PFN_vkGetPhysicalDeviceMemoryProperties2)p2;
    return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL create_device(VkPhysicalDevice pd, const VkDeviceCreateInfo *info,
                                                    const VkAllocationCallbacks *alloc, VkDevice *device) {
    VkLayerDeviceCreateInfo *link = (VkLayerDeviceCreateInfo *)info->pNext;
    while (link && !(link->sType == VK_STRUCTURE_TYPE_LOADER_DEVICE_CREATE_INFO && link->function == VK_LAYER_LINK_INFO))
        link = (VkLayerDeviceCreateInfo *)link->pNext;
    if (!link || !link->u.pLayerInfo || !next_create_device)
        return VK_ERROR_INITIALIZATION_FAILED;
    next_gdpa = link->u.pLayerInfo->pfnNextGetDeviceProcAddr;
    link->u.pLayerInfo = link->u.pLayerInfo->pNext;
    return next_create_device(pd, info, alloc, device);
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL get_device_proc_addr(VkDevice device, const char *name) {
    if (!strcmp(name, "vkGetDeviceProcAddr"))
        return (PFN_vkVoidFunction)get_device_proc_addr;
    return next_gdpa ? next_gdpa(device, name) : NULL;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL get_instance_proc_addr(VkInstance instance, const char *name) {
    static const struct { const char *name; PFN_vkVoidFunction fn; } mine[] = {
        {"vkGetInstanceProcAddr", (PFN_vkVoidFunction)get_instance_proc_addr},
        {"vkGetDeviceProcAddr", (PFN_vkVoidFunction)get_device_proc_addr},
        {"vkCreateInstance", (PFN_vkVoidFunction)create_instance},
        {"vkCreateDevice", (PFN_vkVoidFunction)create_device},
        {"vkGetPhysicalDeviceMemoryProperties", (PFN_vkVoidFunction)props},
        {"vkGetPhysicalDeviceMemoryProperties2", (PFN_vkVoidFunction)props2},
        {"vkGetPhysicalDeviceMemoryProperties2KHR", (PFN_vkVoidFunction)props2},
    };
    for (size_t i = 0; i < sizeof mine / sizeof *mine; i++)
        if (!strcmp(name, mine[i].name))
            return mine[i].fn;
    return next_gipa ? next_gipa(instance, name) : NULL;
}

__attribute__((visibility("default"))) VKAPI_ATTR VkResult VKAPI_CALL
vkNegotiateLoaderLayerInterfaceVersion(VkNegotiateLayerInterface *v) {
    if (!v || v->sType != LAYER_NEGOTIATE_INTERFACE_STRUCT)
        return VK_ERROR_INITIALIZATION_FAILED;
    if (v->loaderLayerInterfaceVersion > 2)
        v->loaderLayerInterfaceVersion = 2;
    v->pfnGetInstanceProcAddr = get_instance_proc_addr;
    v->pfnGetDeviceProcAddr = get_device_proc_addr;
    v->pfnGetPhysicalDeviceProcAddr = NULL;
    return VK_SUCCESS;
}
